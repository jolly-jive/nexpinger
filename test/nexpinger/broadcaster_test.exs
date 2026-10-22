defmodule NexPinger.BroadcasterTest do
  # Counts a subscriber's mailbox: no other test may publish meanwhile
  use ExUnit.Case, async: false

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

  describe "a subscriber that falls behind" do
    # Takes messages only when told, so its mailbox holds what the test sent
    defp start_slow_subscriber do
      test = self()
      spawn_link(fn -> slow_loop(test) end)
    end

    defp slow_loop(test) do
      receive do
        {:take, count} ->
          for _ <- 1..count do
            receive do
              message -> send(test, {:taken, message})
            end
          end

          slow_loop(test)
      end
    end

    defp take(subscriber, count) do
      send(subscriber, {:take, count})

      for _ <- 1..count do
        assert_receive {:taken, message}
        message
      end
    end

    defp publish(host, item, n) do
      Broadcaster.publish(host, item, {:ok, n * 1.0}, "2026-09-30 12:00:00.00#{n}")
    end

    test "gets its results up to the cap, then the dropped counts once it is down to half" do
      host = %Host{name: "slow", address: "192.0.2.1", items: []}
      a = %Item{name: "a", type: :icmp}
      b = %Item{name: "b", type: :icmp}
      subscriber = start_slow_subscriber()
      Broadcaster.subscribe(subscriber, max_queue: 4)

      for n <- 1..6, do: publish(host, a, n)
      :sys.get_state(Broadcaster)
      assert {:message_queue_len, 4} = Process.info(subscriber, :message_queue_len)

      # 3 waiting: below the cap, but not yet down to half
      take(subscriber, 1)
      publish(host, b, 7)
      :sys.get_state(Broadcaster)
      assert {:message_queue_len, 3} = Process.info(subscriber, :message_queue_len)

      take(subscriber, 2)
      publish(host, a, 8)
      # Before the next :take, which would count as waiting
      :sys.get_state(Broadcaster)

      assert [
               {:item_result, ^host, ^a, {:ok, 4.0}, _},
               {:results_dropped,
                [
                  %{
                    item: ^a,
                    count: 2,
                    first_at: "2026-09-30 12:00:00.005",
                    last_at: "2026-09-30 12:00:00.006"
                  },
                  %{
                    item: ^b,
                    count: 1,
                    first_at: "2026-09-30 12:00:00.007",
                    last_at: "2026-09-30 12:00:00.007"
                  }
                ]},
               {:item_result, ^host, ^a, {:ok, 8.0}, _}
             ] = take(subscriber, 3)
    end

    test "does not hold up the other subscribers" do
      host = %Host{name: "slow-other", address: "192.0.2.1", items: []}
      item = %Item{name: "a", type: :icmp}
      Broadcaster.subscribe(start_slow_subscriber(), max_queue: 1)
      Broadcaster.subscribe(self())

      for n <- 1..3, do: publish(host, item, n)

      for n <- 1..3 do
        rtt = n * 1.0
        assert_receive {:item_result, ^host, ^item, {:ok, ^rtt}, _timestamp}
      end
    end

    test "rejects a cap that is not a positive integer" do
      assert_raise ArgumentError, fn -> Broadcaster.subscribe(self(), max_queue: 0) end
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
