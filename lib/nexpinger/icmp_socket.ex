defmodule NexPinger.IcmpSocket do
  @moduledoc """
  Sends one Echo over an unprivileged Linux ICMP socket
  (SOCK_DGRAM + IPPROTO_ICMP / IPPROTO_ICMPV6) and measures the RTT.

  If the socket can't be opened (user's group not in `net.ipv4.ping_group_range`,
  OTP without :socket, etc.), returns `{:error, :unavailable}`;
  the caller then falls back to the ping command.
  """

  import Bitwise

  @echo_request_v4 8
  @echo_reply_v4 0
  @echo_request_v6 128
  @echo_reply_v6 129
  @payload_size 32

  @type result :: {:ok, rtt_ms :: float()} | {:error, String.t()} | {:error, :unavailable}

  @spec ping(String.t(), non_neg_integer()) :: result()
  def ping(address, timeout_ms) do
    with {:ok, family, ip} <- resolve(address),
         {:ok, socket} <- open(family) do
      try do
        echo(socket, family, ip, timeout_ms)
      after
        :socket.close(socket)
      end
    end
  end

  defp resolve(address) do
    charlist = to_charlist(address)

    case :inet.parse_address(charlist) do
      {:ok, ip} when tuple_size(ip) == 4 ->
        {:ok, :inet, ip}

      {:ok, ip} ->
        {:ok, :inet6, ip}

      {:error, _} ->
        case :inet.getaddr(charlist, :inet) do
          {:ok, ip} ->
            {:ok, :inet, ip}

          {:error, _} ->
            case :inet.getaddr(charlist, :inet6) do
              {:ok, ip} -> {:ok, :inet6, ip}
              {:error, _} -> {:error, "unknown host"}
            end
        end
    end
  end

  @doc """
  Checks whether ICMP sockets work (opens and closes an IPv4 socket).
  Returns the reason if not.
  """
  @spec availability() :: :ok | {:error, String.t()}
  def availability do
    case open_socket(:inet) do
      {:ok, socket} ->
        :socket.close(socket)
        :ok

      {:error, reason} ->
        {:error, unavailable_reason(reason)}
    end
  end

  defp open(family) do
    case open_socket(family) do
      {:ok, socket} -> {:ok, socket}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp open_socket(family) do
    protocol = if family == :inet, do: :icmp, else: :"ipv6-icmp"
    :socket.open(family, :dgram, protocol)
  rescue
    # OTP built without :socket (NIF)
    _error -> {:error, :socket_not_supported}
  catch
    _kind, _reason -> {:error, :socket_not_supported}
  end

  defp unavailable_reason(reason) when reason in [:eacces, :eperm],
    do: "permission denied; net.ipv4.ping_group_range does not include this user's groups"

  defp unavailable_reason(reason) when reason in [:eprotonosupport, :eafnosupport, :esocktnosupport],
    do: "the kernel does not support ICMP datagram sockets"

  defp unavailable_reason(:socket_not_supported),
    do: "this Erlang/OTP runtime does not support :socket"

  defp unavailable_reason(reason), do: "cannot open an ICMP socket (#{inspect(reason)})"

  defp echo(socket, family, ip, timeout_ms) do
    seq = :rand.uniform(0x10000) - 1
    payload = :rand.bytes(@payload_size)
    {request_type, reply_type} = echo_types(family)

    # The kernel sets the identifier per socket and delivers only matching replies.
    # It also computes the ICMPv6 checksum.
    packet = build_packet(request_type, 0, seq, payload, family == :inet)

    started = System.monotonic_time(:microsecond)
    deadline = started + timeout_ms * 1000

    # Once connected, Destination Unreachable arrives as a socket error
    with :ok <- :socket.connect(socket, %{family: family, addr: ip, port: 0}),
         :ok <- :socket.send(socket, packet, timeout_ms) do
      await_reply(socket, reply_type, seq, payload, started, deadline)
    else
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  defp echo_types(:inet), do: {@echo_request_v4, @echo_reply_v4}
  defp echo_types(:inet6), do: {@echo_request_v6, @echo_reply_v6}

  defp await_reply(socket, reply_type, seq, payload, started, deadline) do
    remaining_ms = div(deadline - System.monotonic_time(:microsecond), 1000)

    if remaining_ms <= 0 do
      {:error, "timeout"}
    else
      case :socket.recv(socket, 0, remaining_ms) do
        {:ok, reply} ->
          if reply?(reply, reply_type, seq, payload) do
            {:ok, (System.monotonic_time(:microsecond) - started) / 1000.0}
          else
            await_reply(socket, reply_type, seq, payload, started, deadline)
          end

        {:error, :timeout} ->
          {:error, "timeout"}

        {:error, reason} ->
          {:error, error_message(reason)}
      end
    end
  end

  @doc false
  @spec reply?(binary(), non_neg_integer(), non_neg_integer(), binary()) :: boolean()
  def reply?(<<type, _code, _checksum::16, _id::16, seq::16, data::binary>>, type, seq, payload),
    do: data == payload

  def reply?(_packet, _type, _seq, _payload), do: false

  @doc false
  @spec build_packet(non_neg_integer(), non_neg_integer(), non_neg_integer(), binary(), boolean()) ::
          binary()
  def build_packet(type, id, seq, payload, with_checksum?) do
    packet = <<type, 0, 0::16, id::16, seq::16, payload::binary>>

    if with_checksum? do
      <<type, 0, checksum(packet)::16, id::16, seq::16, payload::binary>>
    else
      packet
    end
  end

  @doc false
  @spec checksum(binary()) :: non_neg_integer()
  def checksum(data) do
    data = if rem(byte_size(data), 2) == 1, do: data <> <<0>>, else: data
    sum = for <<word::16 <- data>>, reduce: 0, do: (acc -> acc + word)
    sum = (sum &&& 0xFFFF) + (sum >>> 16)
    sum = (sum &&& 0xFFFF) + (sum >>> 16)
    bnot(sum) &&& 0xFFFF
  end

  defp error_message(reason)
       when reason in [:ehostunreach, :enetunreach, :econnrefused, :ehostdown, :enetdown],
       do: "unreachable"

  defp error_message(:timeout), do: "timeout"
  defp error_message(reason), do: inspect(reason)
end
