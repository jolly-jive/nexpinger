defmodule ExPingNext.CLI do
  @moduledoc """
  escript のエントリポイント。
  使い方: exping_next [設定ファイルパス]  (省略時は config/hosts.yml)
  """

  alias ExPingNext.{Config, Runner}

  @spec default_config_path() :: String.t()
  def default_config_path, do: "config/hosts.yml"

  def main(argv) do
    path = List.first(argv) || default_config_path()

    case Config.load(path) do
      {:ok, []} ->
        IO.puts(:stderr, "設定ファイルに監視対象ホストが1件もありません: #{path}")
        System.halt(1)

      {:ok, hosts} ->
        IO.puts("ExPing Next (Elixir CUI) 起動 — #{length(hosts)} 台を監視します (#{path})")
        IO.puts(String.duplicate("-", 60))

        Enum.each(hosts, fn host ->
          case DynamicSupervisor.start_child(ExPingNext.MonitorSupervisor, {Runner, host}) do
            {:ok, _pid} -> :ok
            {:error, reason} -> IO.puts(:stderr, "監視対象の起動に失敗しました: #{inspect(reason)}")
          end
        end)

        # メインプロセスは常駐させる（Ctrl+C で終了）
        Process.sleep(:infinity)

      {:error, reason} ->
        IO.puts(:stderr, "設定ファイルの読み込みに失敗しました: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
