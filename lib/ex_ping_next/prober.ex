defmodule ExPingNext.Prober do
  @moduledoc """
  1回分の疎通確認を実行する。
  ICMP は特権不要の方式で送る。
    * Linux: ICMP datagram ソケット（`ExPingNext.IcmpSocket`）。使えなければ ping コマンド
    * その他: OS の ping コマンド
  TCP は :gen_tcp.connect の成否とRTTを計測する。
  """

  alias ExPingNext.{Host, IcmpSocket, Item}

  @type result :: {:ok, rtt_ms :: float()} | {:error, reason :: String.t()}

  @spec probe(Host.t(), Item.t()) :: result()
  def probe(%Host{} = host, %Item{type: :icmp} = item), do: icmp_probe(host, item)
  def probe(%Host{} = host, %Item{type: :tcp} = item), do: tcp_probe(host, item)

  @doc """
  この環境で ICMP 監視に使う方法を英語で返す（起動時の表示用）。
  """
  @spec icmp_method() :: String.t()
  def icmp_method do
    case :os.type() do
      {:unix, :linux} ->
        case IcmpSocket.availability() do
          :ok -> "ICMP socket"
          {:error, reason} -> "ping command (fallback: #{reason})"
        end

      _ ->
        "ping command"
    end
  end

  # ---- ICMP ----------------------------------------------------------

  defp icmp_probe(%Host{address: address}, %Item{timeout: timeout}) do
    case :os.type() do
      {:unix, :linux} ->
        case IcmpSocket.ping(address, timeout) do
          {:error, :unavailable} -> ping_command_probe(address, timeout)
          result -> result
        end

      _ ->
        ping_command_probe(address, timeout)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp ping_command_probe(address, timeout) do
    args = icmp_args(address, timeout)

    task = Task.async(fn -> System.cmd("ping", args, ping_cmd_opts()) end)

    case Task.yield(task, timeout + 500) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        parse_ping_time(output)

      {:ok, {_output, _exit_code}} ->
        {:error, "unreachable"}

      nil ->
        {:error, "timeout"}
    end
  end

  # Unix では出力を英語・小数点 "." に固定する（LANG によって "time=" の翻訳や "0,045" になるのを防ぐ）
  defp ping_cmd_opts do
    case :os.type() do
      {:unix, _} -> [stderr_to_stdout: true, env: [{"LC_ALL", "C"}]]
      _ -> [stderr_to_stdout: true]
    end
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

  defp tcp_probe(%Host{address: address}, %Item{port: port, timeout: timeout}) do
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
