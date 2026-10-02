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
      NexPinger.IcmpHelper,
      NexPinger.MacResolver
    ]

    {:ok, supervisor} =
      Supervisor.start_link(children, strategy: :one_for_one, name: NexPinger.Supervisor)

    # Burrito (mix release) does not call the escript main_module, so start the CLI here.
    # As an escript, the escript calls CLI.main/1 instead.
    #
    # Burrito starts the VM with `erl -s elixir start_cli ... -extra <args>`. If start/2 returns,
    # Kernel.CLI parses the user's args: it grabs --help, runs the config file as an Elixir
    # script, and halts the VM (no --no-halt). So run CLI.main/1 here and exit via System.halt/1.
    if burrito?() do
      argv = :init.get_plain_arguments() |> Enum.map(&to_string/1)
      NexPinger.CLI.main(argv)
    end

    {:ok, supervisor}
  end

  defp burrito?, do: System.get_env("__BURRITO") != nil
end
