defmodule NexPinger.RunnerTest do
  use ExUnit.Case, async: false

  alias NexPinger.{Broadcaster, Host, Item, Runner}

  defmodule NamedSubscriber do
    use GenServer

    def start_link(name, owner) do
      GenServer.start_link(__MODULE__, owner, name: name)
    end

    def init(owner), do: {:ok, %{owner: owner}}

    def handle_info({:item_result, host, item, event}, %{owner: owner} = state) do
      send(owner, {:named_result, host, item, event})
      {:noreply, state}
    end
  end

  test "starts a monitor process for a host under a supervisor" do
    {:ok, supervisor} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: NexPinger.TestSupervisor
      )

    host = %Host{
      name: "local-test",
      address: "127.0.0.1",
      ip: {127, 0, 0, 1},
      resolved: "127.0.0.1",
      items: []
    }

    item = %Item{name: "icmp", type: :icmp, interval: 10, timeout: 100}

    assert {:ok, pid} = DynamicSupervisor.start_child(supervisor, {Runner, {host, item}})
    assert Process.alive?(pid)

    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  test "publishes probe result to registered subscribers" do
    host = %Host{
      name: "broadcaster-test",
      address: "127.0.0.1",
      items: []
    }

    item = %Item{name: "icmp", type: :icmp, interval: 10, timeout: 100}

    Broadcaster.subscribe(self())
    assert :ok = Broadcaster.publish(host, item, {:ok, 12.34})

    assert_receive {:item_result, ^host, ^item, {:ok, 12.34}}
  end

  test "publishes probe result to a named subscriber" do
    host = %Host{
      name: "named-broadcaster-test",
      address: "127.0.0.1",
      items: []
    }

    item = %Item{name: "icmp", type: :icmp, interval: 10, timeout: 100}

    {:ok, _pid} = NamedSubscriber.start_link(:named_subscriber_test, self())
    assert :ok = Broadcaster.subscribe(:named_subscriber_test)
    assert :ok = Broadcaster.publish(host, item, {:ok, 7.89})

    assert_receive {:named_result, ^host, ^item, {:ok, 7.89}}
  end

  test "fires the first probe immediately after startup" do
    host = %Host{
      name: "immediate-check",
      address: "127.0.0.1",
      ip: {127, 0, 0, 1},
      resolved: "127.0.0.1",
      items: []
    }

    item = %Item{name: "icmp", type: :icmp, interval: 5000, timeout: 200}

    Broadcaster.subscribe(self())
    {:ok, pid} = Runner.start_link({host, item})

    assert_receive {:item_result, %Host{name: "immediate-check"}, ^item, {:ok, _rtt}}, 1000

    Process.exit(pid, :kill)
  end

  test "publishes an NG result and keeps running when the probe raises" do
    host = %Host{
      name: "raising-probe",
      address: "127.0.0.1",
      ip: {127, 0, 0, 1},
      resolved: "127.0.0.1",
      items: []
    }

    # No Prober.probe/2 clause matches an unknown type
    item = %Item{name: "bogus", type: :bogus, interval: 10, timeout: 100}

    Broadcaster.subscribe(self())
    {:ok, pid} = Runner.start_link({host, item})

    assert_receive {:item_result, %Host{name: "raising-probe"}, ^item, {:error, reason}}, 1000
    assert reason =~ "no function clause matching"
    refute reason =~ "\n"
    assert_receive {:item_result, %Host{name: "raising-probe"}, ^item, {:error, _reason}}, 1000
    assert Process.alive?(pid)

    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  test "looks up the MAC of on-link hosts only" do
    Broadcaster.subscribe(self())

    # The probe raises (unknown type) and never touches the network; the MAC lookup
    # still runs. Each resolved IP is unique, so its MacResolver cache entry tells.
    for {on_link, resolved} <- [{false, "192.0.2.141"}, {true, "192.0.2.142"}] do
      host = %Host{
        name: "mac-lookup-#{on_link}",
        address: resolved,
        ip: {127, 0, 0, 1},
        resolved: resolved,
        on_link: on_link,
        items: []
      }

      item = %Item{name: "bogus", type: :bogus, interval: 5000, timeout: 100}
      {:ok, pid} = Runner.start_link({host, item})
      assert_receive {:item_result, %Host{name: "mac-lookup-" <> _}, ^item, _result}, 1000
      Process.unlink(pid)
      Process.exit(pid, :kill)

      assert match?([_], :ets.lookup(NexPinger.MacResolver, resolved)) == on_link
    end
  end

  describe "next_start/3" do
    test "keeps the interval start to start when the probe is shorter than the interval" do
      assert Runner.next_start(1000, 1000, 1000) == 2000
      assert Runner.next_start(1000, 1000, 1350) == 2000
      assert Runner.next_start(1000, 1000, 1999) == 2000
    end

    test "starts on time when the probe ends exactly at the next start" do
      assert Runner.next_start(1000, 1000, 2000) == 2000
    end

    test "skips the starts missed by a long probe" do
      assert Runner.next_start(1000, 1000, 2001) == 3000
      assert Runner.next_start(1000, 1000, 4500) == 5000
    end

    test "never schedules before the last start" do
      assert Runner.next_start(1000, 1000, 900) == 2000
    end
  end

  test "publishes to stdout and file subscribers at the same time" do
    host = %Host{
      name: "dual-output",
      address: "127.0.0.1",
      items: []
    }

    item = %Item{name: "icmp", type: :icmp, interval: 10, timeout: 100}

    path = "/tmp/nexpinger_dual_output.log"
    File.rm(path)

    {:ok, _pid} =
      NexPinger.FileSubscriber.start_link(path: path, name: :test_file_subscriber, owner: self())

    assert :ok = Broadcaster.subscribe(self())
    assert :ok = Broadcaster.subscribe(:test_file_subscriber)
    assert :ok = Broadcaster.publish(host, item, {:ok, 99.99})

    assert_receive {:item_result, ^host, ^item, {:ok, 99.99}}
    assert_receive {:file_written, ^path}
    assert {:ok, content} = File.read(path)
    assert String.contains?(content, "dual-output")
  end

  test "keeps the result columns aligned when a MAC address is unavailable" do
    with_mac = %Host{
      name: "with-mac",
      address: "192.168.0.1",
      items: [],
      mac_address: "00:00:5e:00:53:01"
    }

    item = %Item{name: "icmp", type: :icmp}

    without_mac = %{with_mac | name: "without-mac", mac_address: nil}
    mac_path = "/tmp/nexpinger_with_mac.log"
    no_mac_path = "/tmp/nexpinger_without_mac.log"
    File.rm(mac_path)
    File.rm(no_mac_path)

    {:ok, mac_pid} = NexPinger.FileSubscriber.start_link(path: mac_path, owner: self())
    {:ok, no_mac_pid} = NexPinger.FileSubscriber.start_link(path: no_mac_path, owner: self())
    send(mac_pid, {:item_result, with_mac, item, {:ok, 1.23}})
    send(no_mac_pid, {:item_result, without_mac, item, {:ok, 1.23}})

    assert_receive {:file_written, ^mac_path}
    assert_receive {:file_written, ^no_mac_path}
    {:ok, mac_line} = File.read(mac_path)
    {:ok, no_mac_line} = File.read(no_mac_path)
    assert mac_line =~ " 00:00:5e:00:53:01 icmp icmp ok"
    assert no_mac_line =~ " -                 icmp icmp ok"
  end
end
