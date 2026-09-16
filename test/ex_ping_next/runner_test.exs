defmodule ExPingNext.RunnerTest do
  use ExUnit.Case, async: false

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

  test "publishes to stdout and file subscribers at the same time" do
    host = %Host{
      name: "dual-output",
      address: "127.0.0.1",
      type: :icmp,
      interval: 10,
      timeout: 100
    }

    path = "/tmp/ex_ping_next_dual_output.log"
    File.rm(path)

    {:ok, _pid} = ExPingNext.FileSubscriber.start_link(path, :test_file_subscriber, self())
    assert :ok = Broadcaster.subscribe(self())
    assert :ok = Broadcaster.subscribe(:test_file_subscriber)
    assert :ok = Broadcaster.publish(host, {:ok, 99.99})

    assert_receive {:host_result, ^host, {:ok, 99.99}}
    assert_receive {:file_written, ^path}
    assert {:ok, content} = File.read(path)
    assert String.contains?(content, "dual-output")
  end

  test "keeps the result columns aligned when a MAC address is unavailable" do
    with_mac = %Host{
      name: "with-mac",
      address: "192.168.0.1",
      type: :icmp,
      mac_address: "08:33:ed:8f:c1:f2"
    }

    without_mac = %{with_mac | name: "without-mac", mac_address: nil}
    mac_path = "/tmp/ex_ping_next_with_mac.log"
    no_mac_path = "/tmp/ex_ping_next_without_mac.log"
    File.rm(mac_path)
    File.rm(no_mac_path)

    {:ok, mac_pid} = ExPingNext.FileSubscriber.start_link(mac_path, nil, self())
    {:ok, no_mac_pid} = ExPingNext.FileSubscriber.start_link(no_mac_path, nil, self())
    send(mac_pid, {:host_result, with_mac, {:ok, 1.23}})
    send(no_mac_pid, {:host_result, without_mac, {:ok, 1.23}})

    assert_receive {:file_written, ^mac_path}
    assert_receive {:file_written, ^no_mac_path}
    {:ok, mac_line} = File.read(mac_path)
    {:ok, no_mac_line} = File.read(no_mac_path)
    assert mac_line =~ ") 08:33:ed:8f:c1:f2 ICMP"
    assert no_mac_line =~ ")                   ICMP"
  end
end
