defmodule ExPingNext.CLI do
  @moduledoc """
  escript のエントリポイント。
  使い方: exping_next [--log-file PATH] [--no-stdout] [--help] [設定ファイルパス...]
  """

  alias ExPingNext.{Config, Runner}

  @usage """
  Usage: exping_next [options] <config file>...

    --log-file PATH     write monitoring results to a log file
    --no-stdout         disable console output
    --help              show this help message

  """

  @spec parse_options([String.t()]) :: {[log_file: String.t()], [String.t()], [String.t()]}
  def parse_options(argv) do
    OptionParser.parse(argv,
      strict: [
        log_file: :string,
        no_stdout: :boolean,
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

    if Keyword.get(opts, :help, false) do
      IO.puts(@usage)
      System.halt(0)
    end

    log_file = Keyword.get(opts, :log_file)
    stdout_enabled = not Keyword.get(opts, :no_stdout, false)

    case args do
      [] ->
        IO.puts(:stderr, "設定ファイルのパスを指定してください")
        System.halt(1)

      paths ->
        run(paths, log_file, stdout_enabled)
    end
  end

  defp run(paths, log_file, stdout_enabled) do
    case load_hosts(paths) do
      {:ok, []} ->
        IO.puts(:stderr, "設定ファイルに監視対象ホストが1件もありません: #{Enum.join(paths, ", ")}")
        System.halt(1)

      {:ok, hosts} ->
        item_count = Enum.sum(Enum.map(hosts, &length(&1.items)))

        IO.puts(
          "ExPing Next (Elixir CUI) 起動 — #{length(hosts)} 台 / #{item_count} 項目を監視します (#{Enum.join(paths, ", ")})"
        )

        if log_file do
          IO.puts("ログ出力: #{log_file}")
        end

        IO.puts("stdout: #{if stdout_enabled, do: "enabled", else: "disabled"}")
        IO.puts(String.duplicate("-", 60))

        if log_file do
          start_log_file_subscriber(log_file)
        end

        if stdout_enabled do
          ExPingNext.Broadcaster.subscribe(ExPingNext.ConsoleSubscriber)
        end

        Enum.each(hosts, fn host ->
          Enum.each(host.items, fn item ->
            case DynamicSupervisor.start_child(
                   ExPingNext.MonitorSupervisor,
                   {Runner, {host, item}}
                 ) do
              {:ok, _pid} -> :ok
              {:error, reason} -> IO.puts(:stderr, "監視項目の起動に失敗しました: #{inspect(reason)}")
            end
          end)
        end)

        # メインプロセスは常駐させる（Ctrl+C で終了）
        Process.sleep(:infinity)

      {:error, reason} ->
        IO.puts(:stderr, "設定ファイルの読み込みに失敗しました: #{inspect(reason)}")
        System.halt(1)
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
        ExPingNext.FileSubscriber.start_link(log_file, :log_file_subscriber)
        ExPingNext.Broadcaster.subscribe(:log_file_subscriber)

      _pid ->
        :ok
    end
  end
end
