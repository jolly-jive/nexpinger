defmodule NexPinger.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: NexPinger.MonitorRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: NexPinger.MonitorSupervisor},
      NexPinger.Broadcaster,
      NexPinger.ConsoleSubscriber,
      NexPinger.IcmpHelper
    ]

    {:ok, supervisor} =
      Supervisor.start_link(children, strategy: :one_for_one, name: NexPinger.Supervisor)

    # Burrito（mix release）では escript の main_module が呼ばれないため、ここで CLI を起動する。
    # escript 実行時は escript 側が CLI.main/1 を呼ぶので何もしない。
    #
    # Burrito は `erl -s elixir start_cli ... -extra <引数>` で起動するため、start/2 が戻ると
    # Kernel.CLI がユーザーの引数を解釈してしまう（--help を横取りする、設定ファイルを
    # Elixir スクリプトとして実行しようとする、--no-halt が無いので VM を終了する）。
    # それを避けるため、CLI.main/1 は start/2 の中で同期的に実行し、終了は System.halt/1 で行う。
    if burrito?() do
      argv = :init.get_plain_arguments() |> Enum.map(&to_string/1)
      NexPinger.CLI.main(argv)
    end

    {:ok, supervisor}
  end

  defp burrito?, do: System.get_env("__BURRITO") != nil
end
