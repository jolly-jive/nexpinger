defmodule NexPinger.Prober do
  @moduledoc """
  Runs one reachability check against a resolved IP (`NexPinger.Resolver`).
  ICMP is sent without privileges:
    * Linux: ICMP datagram socket (`NexPinger.IcmpSocket`), else the ping command
    * Windows: IcmpSendEcho2 helper (`NexPinger.IcmpHelper`), else the ping command
    * Other: the OS ping command
  TCP: checks :gen_tcp.connect and measures the RTT.
  UDP: sends a service request and waits for any reply (`NexPinger.UdpProbe`).
  """

  alias NexPinger.{IcmpHelper, IcmpSocket, Item, Resolver, UdpProbe}

  @type result :: {:ok, rtt_ms :: float()} | {:error, reason :: String.t()}

  @spec probe(:inet.ip_address(), Item.t()) :: result()
  def probe(ip, %Item{type: :icmp} = item), do: icmp_probe(ip, item)
  def probe(ip, %Item{type: :tcp} = item), do: tcp_probe(ip, item)

  def probe(ip, %Item{type: :udp} = item),
    do: UdpProbe.probe(ip, item.service, item.port, item.timeout)

  @doc """
  Returns the ICMP method used here, for the startup message.
  """
  @spec icmp_method() :: String.t()
  def icmp_method do
    case {ping_command_forced?(), :os.type()} do
      {true, _os} ->
        "ping command (forced by --ping-command)"

      {_, {:unix, :linux}} ->
        case IcmpSocket.availability() do
          :ok -> "ICMP socket"
          {:error, reason} -> "ping command (fallback: #{reason})"
        end

      {_, {:win32, _}} ->
        case IcmpHelper.availability() do
          :ok -> "IcmpSendEcho2 (icmp_helper.exe)"
          {:error, reason} -> "ping command (fallback: #{reason})"
        end

      _ ->
        "ping command"
    end
  end

  @doc """
  Always use the OS ping command, not the ICMP socket or helper (`--ping-command`).
  """
  @spec force_ping_command() :: :ok
  def force_ping_command, do: Application.put_env(:nexpinger, :force_ping_command, true)

  defp ping_command_forced?, do: Application.get_env(:nexpinger, :force_ping_command, false)

  # ---- ICMP ----------------------------------------------------------

  defp icmp_probe(ip, %Item{timeout: timeout}) do
    address = Resolver.to_string(ip)

    result =
      case {ping_command_forced?(), :os.type()} do
        {true, _os} -> {:error, :unavailable}
        {_, {:unix, :linux}} -> IcmpSocket.ping(ip, timeout)
        {_, {:win32, _}} -> IcmpHelper.ping(address, timeout)
        _ -> {:error, :unavailable}
      end

    case result do
      {:error, :unavailable} -> ping_command_probe(address, timeout)
      result -> result
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp ping_command_probe(address, timeout) do
    args = icmp_args(address, timeout)

    task = Task.async(fn -> System.cmd("ping", args, ping_cmd_opts()) end)

    case Task.yield(task, timeout + 500) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        parse_ping_time(output, :os.type(), address)

      {:ok, {_output, _exit_code}} ->
        {:error, "unreachable"}

      nil ->
        {:error, "timeout"}
    end
  end

  # Unix: force English and "." decimals (LANG may localize "time=" or print "0,045")
  defp ping_cmd_opts do
    case :os.type() do
      {:unix, _} -> [stderr_to_stdout: true, env: [{"LC_ALL", "C"}]]
      _ -> [stderr_to_stdout: true]
    end
  end

  defp icmp_args(address, timeout_ms) do
    case :os.type() do
      {:unix, :darwin} ->
        # macOS: -W in ms
        ["-c", "1", "-W", Integer.to_string(timeout_ms), address]

      {:unix, _linux} ->
        # Linux: -W in seconds (rounded up, min 1)
        timeout_sec = max(1, div(timeout_ms + 999, 1000))
        ["-c", "1", "-W", Integer.to_string(timeout_sec), address]

      {:win32, _} ->
        ["-n", "1", "-w", Integer.to_string(timeout_ms), address]
    end
  end

  # Windows ping.exe localizes "time"/"ms", and no env var forces English.
  # IPv4: "TTL=" is never localized, so take the "=<n>" or "<<n>" just before it as the RTT.
  # e.g. "時間 =10ms TTL=117", "Zeit<1ms TTL=128", "temps=10 ms TTL=117", "время=10мс TTL=117"
  # IPv6 replies have no TTL=. Take the first "=<n>" or "<<n>" after "<address>...:" on the
  # reply line, e.g. "Reply from ::1: time<1ms", "::1 からの応答: 時間 <1ms".
  # The address lines before and after (header, statistics) have no "=<n>".
  # "Destination host unreachable" lines have neither, so they count as failures.
  @doc false
  @spec parse_ping_time(binary(), {atom(), atom()}, String.t()) :: result()
  def parse_ping_time(output, {:win32, _}, address) do
    pattern =
      if String.contains?(address, ":"),
        do: ~r/#{Regex.escape(address)}[^\r\n]*?:[^\r\n]*?[=<]\s*(\d+)/,
        else: ~r/[=<]\s*(\d+)[^=<\r\n]*?TTL=/

    case Regex.run(pattern, output) do
      [_, ms] -> {:ok, String.to_integer(ms) * 1.0}
      nil -> {:error, "no reply"}
    end
  end

  def parse_ping_time(output, _os_type, _address) do
    case Regex.run(~r/time[=<]([\d.]+)\s*ms/i, output) do
      [_, ms] -> {:ok, String.to_float(normalize_float(ms))}
      nil -> {:error, "no reply"}
    end
  end

  defp normalize_float(s) do
    if String.contains?(s, "."), do: s, else: s <> ".0"
  end

  # ---- TCP -------------------------------------------------------------

  defp tcp_probe(ip, %Item{port: port, timeout: timeout}) do
    start = System.monotonic_time(:microsecond)
    options = [:binary, Resolver.socket_family(ip), active: false]

    case :gen_tcp.connect(ip, port, options, timeout) do
      {:ok, socket} ->
        elapsed_us = System.monotonic_time(:microsecond) - start
        :gen_tcp.close(socket)
        {:ok, elapsed_us / 1000.0}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
