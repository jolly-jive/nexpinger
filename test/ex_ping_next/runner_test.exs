defmodule ExPingNext.RunnerTest do
  use ExUnit.Case, async: true

  alias ExPingNext.{Host, Runner}

  test "starts a monitor process for a host under a supervisor" do
    {:ok, supervisor} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: ExPingNext.TestSupervisor
      )

    host = %Host{
      name: "local-test",
      address: "127.0.0.1",
      type: :icmp,
      interval: 10,
      timeout: 100
    }

    assert {:ok, pid} = DynamicSupervisor.start_child(supervisor, {Runner, host})
    assert Process.alive?(pid)

    Process.unlink(pid)
    Process.exit(pid, :kill)
  end
end
