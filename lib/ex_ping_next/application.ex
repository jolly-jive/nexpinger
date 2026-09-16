defmodule ExPingNext.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: ExPingNext.MonitorRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: ExPingNext.MonitorSupervisor},
      ExPingNext.Broadcaster,
      ExPingNext.ConsoleSubscriber
    ]

    {:ok, supervisor} =
      Supervisor.start_link(children, strategy: :one_for_one, name: ExPingNext.Supervisor)

    ExPingNext.Broadcaster.subscribe(ExPingNext.ConsoleSubscriber)

    {:ok, supervisor}
  end
end
