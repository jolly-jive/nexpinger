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
  Returns the ICMP method used here for the given target families, for the startup message.
  """
  @spec icmp_method([Resolver.ip_family()]) :: String.t()
  def icmp_method(families) do
    case {ping_command_forced?(), :os.type()} do
      {true, _os} ->
        "ping command (forced by --ping-command)"

      {_, {:unix, :linux}} ->
        families
        |> Enum.map(&{&1, IcmpSocket.availability(Resolver.socket_family(&1))})
        |> icmp_socket_method()

      {_, {:win32, _}} ->
        case IcmpHelper.availability() do
          :ok -> "IcmpSendEcho2 (icmp_helper.exe)"
          {:error, reason} -> "ping command (fallback: #{reason})"
        end

      _ ->
        "ping command"
    end
  end

  # Per family only when the families differ, e.g. IPv6 disabled in the kernel
  @doc false
  @spec icmp_socket_method([{Resolver.ip_family(), :ok | {:error, String.t()}}]) :: String.t()
  def icmp_socket_method(availabilities) do
    case Enum.uniq_by(availabilities, &elem(&1, 1)) do
      [{_family, availability}] ->
        socket_method(availability)

      _differ ->
        Enum.map_join(availabilities, "; ", fn {family, availability} ->
          "#{Resolver.family_name(family)}: #{socket_method(availability)}"
        end)
    end
  end

  defp socket_method(:ok), do: "ICMP socket"
  defp socket_method({:error, reason}), do: "ping command (fallback: #{reason})"

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
      {:error, :unavailable} -> address |> ping_command_probe(timeout) |> enforce_timeout(timeout)
      result -> enforce_timeout(result, timeout)
    end
  end

  # ping.exe and IcmpSendEcho2 can report replies later than the timeout, and Linux ping -W
  # is rounded up to whole seconds, so a reply slower than the timeout counts as a timeout.
  @doc false
  @spec enforce_timeout(result(), non_neg_integer()) :: result()
  def enforce_timeout({:ok, rtt_ms}, timeout_ms) when rtt_ms > timeout_ms, do: {:error, "timeout"}
  def enforce_timeout(result, _timeout_ms), do: result

  defp ping_command_probe(address, timeout) do
    case System.find_executable("ping") do
      nil ->
        {:error, "ping command not found"}

      path ->
        case run_command(path, icmp_args(address, timeout), ping_env(), timeout + 500) do
          {:ok, output, 0} -> parse_ping_time(output, :os.type(), address)
          {:ok, _output, _exit_code} -> {:error, "unreachable"}
          :timeout -> {:error, "timeout"}
        end
    end
  end

  # Unix: force English and "." decimals (LANG may localize "time=" or print "0,045")
  defp ping_env do
    case :os.type() do
      {:unix, _} -> [{~c"LC_ALL", ~c"C"}]
      _ -> []
    end
  end

  # Like System.cmd/3 with a deadline. On timeout the OS process is killed,
  # since closing the port only closes its pipes and leaves the process running.
  @doc false
  @spec run_command(String.t(), [String.t()], [{charlist(), charlist()}], non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | :timeout
  def run_command(path, args, env, timeout_ms) do
    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args,
        env: env
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    collect_output(port, os_pid, System.monotonic_time(:millisecond) + timeout_ms, [])
  end

  defp collect_output(port, os_pid, deadline, acc) do
    remaining_ms = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, data}} -> collect_output(port, os_pid, deadline, [acc | data])
      {^port, {:exit_status, status}} -> {:ok, IO.iodata_to_binary(acc), status}
    after
      remaining_ms ->
        if os_pid, do: kill_os_process(os_pid)
        close_port(port)
        :timeout
    end
  end

  defp kill_os_process(os_pid) do
    {command, args} =
      case :os.type() do
        {:win32, _} -> {"taskkill", ["/F", "/PID", Integer.to_string(os_pid)]}
        _ -> {"kill", ["-KILL", Integer.to_string(os_pid)]}
      end

    if path = System.find_executable(command) do
      System.cmd(path, args, stderr_to_stdout: true)
    end

    :ok
  end

  # The port may have closed on its own; drop any messages it already sent
  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  after
    flush_port(port)
  end

  defp flush_port(port) do
    receive do
      {^port, _message} -> flush_port(port)
    after
      0 -> :ok
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
        {:error, tcp_error_message(reason)}
    end
  end

  # econnrefused: a RST came back, so the host is up but the port is closed
  @doc false
  @spec tcp_error_message(term()) :: String.t()
  def tcp_error_message(:econnrefused), do: "connection refused"
  def tcp_error_message(:ehostunreach), do: "host unreachable"
  def tcp_error_message(:enetunreach), do: "network unreachable"
  def tcp_error_message(:timeout), do: "timeout"
  def tcp_error_message(reason), do: inspect(reason)
end
