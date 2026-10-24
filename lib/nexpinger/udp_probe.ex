defmodule NexPinger.UdpProbe do
  @moduledoc """
  UDP reachability check.
  Sends a service-specific request that makes the server reply, and counts
  any UDP reply from the target as OK. The reply content is not checked.
  """

  alias NexPinger.{ErrorQueue, Resolver}

  @type service :: :dns | :ntp | :quic
  @type result :: {:ok, rtt_ms :: float()} | {:error, reason :: String.t()}

  @services %{dns: 53, ntp: 123, quic: 443}

  # NTP servers often rate-limit clients that poll faster than this
  @ntp_min_interval 8000

  @doc """
  Returns the known services and their default ports.
  """
  @spec services() :: %{service() => :inet.port_number()}
  def services, do: @services

  @spec ntp_min_interval() :: non_neg_integer()
  def ntp_min_interval, do: @ntp_min_interval

  # A new socket per attempt, connected to the target: the OS drops datagrams
  # from other sources, and late replies to an earlier attempt can't arrive here.
  # Linux uses :socket for IP_RECVERR (`NexPinger.ErrorQueue`), which gen_udp lacks;
  # without it, router errors (Time Exceeded, Host Unreachable) end as timeouts.
  # opts (for tests, Linux only): ttl: sets the TTL / hop limit
  @spec probe(:inet.ip_address(), service(), :inet.port_number(), non_neg_integer(), keyword()) ::
          result()
  def probe(ip, service, port, timeout_ms, opts \\ []) do
    family = Resolver.socket_family(ip)

    case :os.type() do
      {:unix, :linux} -> socket_probe(family, ip, port, payload(service), timeout_ms, opts)
      _ -> gen_udp_probe(family, ip, port, payload(service), timeout_ms)
    end
  end

  defp gen_udp_probe(family, ip, port, packet, timeout_ms) do
    case :gen_udp.open(0, [:binary, family, active: false]) do
      {:ok, socket} ->
        try do
          gen_udp_exchange(socket, ip, port, packet, timeout_ms)
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        {:error, error_message(reason)}
    end
  end

  defp gen_udp_exchange(socket, ip, port, packet, timeout_ms) do
    started = System.monotonic_time(:microsecond)

    with :ok <- :gen_udp.connect(socket, ip, port),
         :ok <- :gen_udp.send(socket, packet),
         {:ok, _reply} <- :gen_udp.recv(socket, 0, timeout_ms) do
      {:ok, (System.monotonic_time(:microsecond) - started) / 1000.0}
    else
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  defp socket_probe(family, ip, port, packet, timeout_ms, opts) do
    case :socket.open(family, :dgram, :udp) do
      {:ok, socket} ->
        try do
          _ = ErrorQueue.enable(socket, family)
          if ttl = opts[:ttl], do: set_ttl(socket, family, ttl)
          socket_exchange(socket, %{family: family, addr: ip, port: port}, packet, timeout_ms)
        after
          :socket.close(socket)
        end

      {:error, reason} ->
        {:error, error_message(reason)}
    end
  end

  defp socket_exchange(socket, address, packet, timeout_ms) do
    started = System.monotonic_time(:microsecond)

    # Bind before connecting, as gen_udp.open(0) does. Under WSL2 mirrored networking,
    # loopback datagrams from an auto-bound socket never reach Linux's own sockets.
    with :ok <- :socket.bind(socket, :any),
         :ok <- :socket.connect(socket, address),
         :ok <- :socket.send(socket, packet, timeout_ms),
         {:ok, _reply} <- :socket.recv(socket, 0, timeout_ms) do
      {:ok, (System.monotonic_time(:microsecond) - started) / 1000.0}
    else
      {:error, :timeout} ->
        {:error, "timeout"}

      {:error, reason} ->
        case ErrorQueue.cause(socket) do
          :ttl_expired -> {:error, "ttl expired"}
          :other -> {:error, error_message(reason)}
        end
    end
  end

  defp set_ttl(socket, :inet, ttl), do: :ok = :socket.setopt(socket, {:ip, :ttl}, ttl)
  defp set_ttl(socket, :inet6, ttl), do: :ok = :socket.setopt(socket, {:ipv6, :unicast_hops}, ttl)

  # ICMP Port Unreachable: Linux reports econnrefused, Windows econnreset
  defp error_message(reason) when reason in [:econnrefused, :econnreset], do: "port unreachable"
  defp error_message(:ehostunreach), do: "host unreachable"
  defp error_message(:enetunreach), do: "network unreachable"
  defp error_message(:timeout), do: "timeout"
  defp error_message(reason), do: inspect(reason)

  # ---- Payloads --------------------------------------------------------

  @doc false
  @spec payload(service()) :: binary()
  # ". SOA", RD=0, no EDNS.
  # SOA keeps the reply small (". NS" fills 512 bytes with 13 NS + glue);
  # TXT would also be small but draws attention from tunneling detectors.
  # RD=0 keeps a resolver from recursing, so the RTT is the server's alone.
  # Without EDNS the reply stays within 512 bytes and is never fragmented.
  def payload(:dns) do
    id = :rand.uniform(0x10000) - 1
    header = <<id::16, 0::16, 1::16, 0::16, 0::16, 0::16>>
    question = <<0, 6::16, 1::16>>
    header <> question
  end

  # NTPv4 client request (LI=0, VN=4, Mode=3), 48 bytes.
  # Random transmit timestamp: some servers drop requests with a zero one.
  def payload(:ntp) do
    <<0x23, 0::size(39)-unit(8), :rand.bytes(8)::binary>>
  end

  # Long header Initial with a reserved version (0x?a?a?a?a, RFC 9000 15).
  # The server can't support it and replies with Version Negotiation, no crypto needed.
  # Padded to 1200 bytes: servers drop smaller Initial packets.
  def payload(:quic) do
    dcid = :rand.bytes(8)
    scid = :rand.bytes(8)
    header = <<0xC0, 0x1A2A3A4A::32, 8, dcid::binary, 8, scid::binary>>
    header <> :binary.copy(<<0>>, 1200 - byte_size(header))
  end
end
