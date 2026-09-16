defmodule ExPingNext.RunnerTest do
  use ExUnit.Case, async: true

  alias ExPingNext.{Broadcaster, Host, Runner}

  defmodule NamedSubscriber do
    use GenServer

    def start_link(name, owner) do
      GenServer.start_link(__MODULE__, owner, name: name)
    end

    def init(owner), do: {:ok, %{owner: owner}}

    def handle_info({:host_result, host, event}, %{owner: owner} = state) do
      send(owner, {:named_result, host, event})
      {:noreply, state}
    end
  end

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

  test "publishes probe result to registered subscribers" do
    host = %Host{
      name: "broadcaster-test",
      address: "127.0.0.1",
      type: :icmp,
      interval: 10,
      timeout: 100
    }

    Broadcaster.subscribe(self())
    assert :ok = Broadcaster.publish(host, {:ok, 12.34})

    assert_receive {:host_result, ^host, {:ok, 12.34}}
  end

  test "publishes probe result to a named subscriber" do
    host = %Host{
      name: "named-broadcaster-test",
      address: "127.0.0.1",
      type: :icmp,
      interval: 10,
      timeout: 100
    }

    {:ok, _pid} = NamedSubscriber.start_link(:named_subscriber_test, self())
    assert :ok = Broadcaster.subscribe(:named_subscriber_test)
    assert :ok = Broadcaster.publish(host, {:ok, 7.89})

    assert_receive {:named_result, ^host, {:ok, 7.89}}
  end

  test "fires the first probe immediately after startup" do
    host = %Host{
      name: "immediate-check",
      address: "127.0.0.1",
      type: :icmp,
      interval: 5000,
      timeout: 200
    }

    Broadcaster.subscribe(self())
    {:ok, pid} = Runner.start_link(host)

    assert_receive {:host_result, %Host{name: "immediate-check"}, {:ok, _rtt}}, 1000

    Process.exit(pid, :kill)
  end
end
