defmodule ExPingNext.Prober do
  @moduledoc """
  1回分の疎通確認を実行する。
  ICMP は OS の ping コマンドを呼び出す方式（特権不要）。
  TCP は :gen_tcp.connect の成否とRTTを計測する。
  """

  alias ExPingNext.Host

  @type result :: {:ok, rtt_ms :: float()} | {:error, reason :: String.t()}

  @spec probe(Host.t()) :: result()
  def probe(%Host{type: :icmp} = host), do: icmp_probe(host)
  def probe(%Host{type: :tcp} = host), do: tcp_probe(host)

  # ---- ICMP ----------------------------------------------------------

  defp icmp_probe(%Host{address: address, timeout: timeout}) do
    args = icmp_args(address, timeout)

    task = Task.async(fn -> System.cmd("ping", args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout + 500) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        parse_ping_time(output)

      {:ok, {_output, _exit_code}} ->
        {:error, "unreachable"}

      nil ->
        {:error, "timeout"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp icmp_args(address, timeout_ms) do
    case :os.type() do
      {:unix, :darwin} ->
        # macOS: -W はミリ秒
        ["-c", "1", "-W", Integer.to_string(timeout_ms), address]

      {:unix, _linux} ->
        # Linux: -W は秒（切り上げ、最低1秒）
        timeout_sec = max(1, div(timeout_ms + 999, 1000))
        ["-c", "1", "-W", Integer.to_string(timeout_sec), address]

      {:win32, _} ->
        ["-n", "1", "-w", Integer.to_string(timeout_ms), address]
    end
  end

  defp parse_ping_time(output) do
    case Regex.run(~r/time[=<]([\d.]+)\s*ms/i, output) do
      [_, ms] -> {:ok, String.to_float(normalize_float(ms))}
      nil -> {:error, "no reply"}
    end
  end

  defp normalize_float(s) do
    if String.contains?(s, "."), do: s, else: s <> ".0"
  end

  # ---- TCP -------------------------------------------------------------

  defp tcp_probe(%Host{address: address, port: port, timeout: timeout}) do
    start = System.monotonic_time(:microsecond)

    case :gen_tcp.connect(to_charlist(address), port, [:binary, active: false], timeout) do
      {:ok, socket} ->
        elapsed_us = System.monotonic_time(:microsecond) - start
        :gen_tcp.close(socket)
        {:ok, elapsed_us / 1000.0}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
