defmodule NexPinger.CLI do
  @moduledoc """
  escript のエントリポイント。
  使い方: nexpinger [--log-file PATH] [--no-stdout] [--help] [設定ファイルパス...]
  """

  alias NexPinger.{Config, ConsoleSubscriber, Prober, Runner, TerminalInput}

  @usage """
  Usage: nexpinger [options] <config file>...

    --log-file PATH     write monitoring results to a log file
    --no-stdout         disable console output
    --stats-window N    use the last N attempts for RTT statistics (default: 1000)
    --stats-width N     use an 80- or 120-column statistics layout
    --ping-command      always use the OS ping command for ICMP
    --help              show this help message

  """

  @spec parse_options([String.t()]) :: {keyword(), [String.t()], [String.t()]}
  def parse_options(argv) do
    OptionParser.parse(argv,
      strict: [
        log_file: :string,
        no_stdout: :boolean,
        stats_window: :integer,
        stats_width: :integer,
        ping_command: :boolean,
        help: :boolean
      ]
    )
  end

  def main(argv) do
    {opts, args, invalid} = parse_options(argv)

    if invalid != [] do
      invalid_options = Enum.map_join(invalid, ", ", fn {option, _value} -> option end)
      IO.puts(:stderr, "不正なオプションです: #{invalid_options}")
      IO.puts(:stderr, @usage)
      System.halt(1)
    end

    validate_stats_options!(opts)

    if Keyword.get(opts, :help, false) do
      IO.puts(@usage)
      System.halt(0)
    end

    log_file = Keyword.get(opts, :log_file)
    stdout_enabled = not Keyword.get(opts, :no_stdout, false)
    stats_window = Keyword.get(opts, :stats_window, 1000)
    requested_stats_width = Keyword.get(opts, :stats_width)

    if Keyword.get(opts, :ping_command, false) do
      Prober.force_ping_command()
    end

    case args do
      [] ->
        IO.puts(:stderr, "設定ファイルのパスを指定してください")
        System.halt(1)

      paths ->
        run(paths, log_file, stdout_enabled, stats_window, requested_stats_width)
    end
  end

  defp run(paths, log_file, stdout_enabled, stats_window, requested_stats_width) do
    case load_hosts(paths) do
      {:ok, []} ->
        IO.puts(:stderr, "設定ファイルに監視対象ホストが1件もありません: #{Enum.join(paths, ", ")}")
        System.halt(1)

      {:ok, hosts} ->
        item_count = Enum.sum(Enum.map(hosts, &length(&1.items)))
        stats_width = requested_stats_width || TerminalInput.terminal_width()
        stats_height = TerminalInput.terminal_height()
        interactive? = stdout_enabled and TerminalInput.available?()

        ConsoleSubscriber.configure(hosts, stats_window, stats_width, stats_height)

        IO.puts(
          "NexPinger (Elixir CUI) 起動 — #{length(hosts)} 台 / #{item_count} 項目を監視します (#{Enum.join(paths, ", ")})"
        )

        if log_file do
          IO.puts("ログ出力: #{log_file}")
        end

        IO.puts("stdout: #{if stdout_enabled, do: "enabled", else: "disabled"}")

        if Enum.any?(hosts, fn host -> Enum.any?(host.items, &(&1.type == :icmp)) end) do
          IO.puts("ICMP: #{Prober.icmp_method()}")
        end

        IO.puts(String.duplicate("-", 60))

        if log_file do
          start_log_file_subscriber(log_file)
        end

        if stdout_enabled do
          NexPinger.Broadcaster.subscribe(NexPinger.ConsoleSubscriber)
        end

        Enum.each(hosts, fn host ->
          Enum.each(host.items, fn item ->
            case DynamicSupervisor.start_child(
                   NexPinger.MonitorSupervisor,
                   {Runner, {host, item}}
                 ) do
              {:ok, _pid} -> :ok
              {:error, reason} -> IO.puts(:stderr, "監視項目の起動に失敗しました: #{inspect(reason)}")
            end
          end)
        end)

        if interactive? do
          case TerminalInput.run() do
            :quit -> System.halt(0)
            :unavailable -> Process.sleep(:infinity)
          end
        else
          # キー入力が使えないため、メインプロセスは常駐させる（Ctrl+C で終了）
          Process.sleep(:infinity)
        end

      {:error, reason} ->
        IO.puts(:stderr, "設定ファイルの読み込みに失敗しました: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp validate_stats_options!(opts) do
    stats_window = Keyword.get(opts, :stats_window, 1000)
    stats_width = Keyword.get(opts, :stats_width)

    cond do
      stats_window <= 0 ->
        IO.puts(:stderr, "--stats-window は1以上を指定してください")
        System.halt(1)

      not is_nil(stats_width) and stats_width not in [80, 120] ->
        IO.puts(:stderr, "--stats-width は80または120を指定してください")
        System.halt(1)

      true ->
        :ok
    end
  end

  defp load_hosts(paths) do
    result =
      Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, hosts} ->
        case Config.load(path) do
          {:ok, file_hosts} ->
            {:cont, {:ok, [file_hosts | hosts]}}

          {:error, reason} ->
            {:halt, {:error, {path, reason}}}
        end
      end)

    case result do
      {:ok, host_lists} -> {:ok, List.flatten(host_lists)}
      error -> error
    end
  end

  defp start_log_file_subscriber(log_file) do
    case Process.whereis(:log_file_subscriber) do
      nil ->
        NexPinger.FileSubscriber.start_link(log_file, :log_file_subscriber)
        NexPinger.Broadcaster.subscribe(:log_file_subscriber)

      _pid ->
        :ok
    end
  end
end
