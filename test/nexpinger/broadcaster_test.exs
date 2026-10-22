defmodule NexPinger.BroadcasterTest do
  use ExUnit.Case, async: true

  alias NexPinger.{Broadcaster, Host, Item}

  @timestamp "2026-09-30 12:00:00.123"

  defp subscribers, do: :sys.get_state(Broadcaster).subscribers

  describe "subscribe/1" do
    test "returns an error when no process has the name" do
      assert Broadcaster.subscribe(:no_such_subscriber) == {:error, :not_found}
    end

    test "sends each result once to a subscriber that subscribed twice" do
      host = %Host{name: "twice", address: "192.0.2.1", items: []}
      item = %Item{name: "ping", type: :icmp}

      Broadcaster.subscribe(self())
      Broadcaster.subscribe(self())
      Broadcaster.publish(host, item, {:ok, 1.0}, @timestamp)

      assert_receive {:item_result, ^host, ^item, {:ok, 1.0}, @timestamp}
      :sys.get_state(Broadcaster)
      refute_received {:item_result, ^host, ^item, _result, _timestamp}
    end

    test "drops a subscriber that exits" do
      subscriber = spawn(fn -> receive do: (:stop -> :ok) end)
      Broadcaster.subscribe(subscriber)
      assert Map.has_key?(subscribers(), subscriber)

      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}

      # The Broadcaster gets its own :DOWN; nothing orders it before this test's calls
      assert eventually(fn -> not Map.has_key?(subscribers(), subscriber) end)
    end
  end

  defp eventually(check, tries \\ 100) do
    cond do
      check.() ->
        true

      tries > 0 ->
        Process.sleep(10)
        eventually(check, tries - 1)

      true ->
        false
    end
  end
end
