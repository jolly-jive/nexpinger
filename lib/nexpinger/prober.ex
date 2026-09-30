defmodule NexPinger.Prober do
  @moduledoc """
  1回分の疎通確認を実行する。
  ICMP は特権不要の方式で送る。
    * Linux: ICMP datagram ソケット（`NexPinger.IcmpSocket`）。使えなければ ping コマンド
    * Windows: IcmpSendEcho2 を呼ぶ補助プログラム（`NexPinger.IcmpHelper`）。使えなければ ping コマンド
    * その他: OS の ping コマンド
  TCP は :gen_tcp.connect の成否とRTTを計測する。
  """

  alias NexPinger.{Host, IcmpHelper, IcmpSocket, Item}

  @type result :: {:ok, rtt_ms :: float()} | {:error, reason :: String.t()}

  @spec probe(Host.t(), Item.t()) :: result()
  def probe(%Host{} = host, %Item{type: :icmp} = item), do: icmp_probe(host, item)
  def probe(%Host{} = host, %Item{type: :tcp} = item), do: tcp_probe(host, item)

  @doc """
  この環境で ICMP 監視に使う方法を英語で返す（起動時の表示用）。
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
  ICMP ソケットや補助プログラムを使わず、常に OS の ping コマンドを使うようにする（`--ping-command`）。
  """
  @spec force_ping_command() :: :ok
  def force_ping_command, do: Application.put_env(:nexpinger, :force_ping_command, true)

  defp ping_command_forced?, do: Application.get_env(:nexpinger, :force_ping_command, false)

  # ---- ICMP ----------------------------------------------------------

  defp icmp_probe(%Host{address: address}, %Item{timeout: timeout}) do
    result =
      case {ping_command_forced?(), :os.type()} do
        {true, _os} -> {:error, :unavailable}
        {_, {:unix, :linux}} -> IcmpSocket.ping(address, timeout)
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
        parse_ping_time(output, :os.type())

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

  # Windows の ping.exe は表示言語で "time"/"ms" が翻訳され、環境変数で英語に固定できない。
  # 言語に依存しない "TTL=" を手がかりに、その直前の "=<数値>" / "<<数値>" を RTT とする。
  # 例: "時間 =10ms TTL=117", "Zeit<1ms TTL=128", "temps=10 ms TTL=117", "время=10мс TTL=117"
  # "宛先ホストに到達できません" の応答行には TTL= が無いので、失敗として扱われる。
  @doc false
  @spec parse_ping_time(binary(), {atom(), atom()}) :: result()
  def parse_ping_time(output, {:win32, _}) do
    case Regex.run(~r/[=<]\s*(\d+)[^=<\r\n]*?TTL=/, output) do
      [_, ms] -> {:ok, String.to_integer(ms) * 1.0}
      nil -> {:error, "no reply"}
    end
  end

  def parse_ping_time(output, _os_type) do
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
