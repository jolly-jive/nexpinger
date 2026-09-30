defmodule NexPinger.ConsoleSubscriberTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias NexPinger.{ConsoleSubscriber, Host, Item}

  test "beeps when an item result is an error" do
    host = %Host{name: "gateway", address: "192.0.2.1", items: []}
    item = %Item{name: "ping", type: :icmp}
    {:ok, state} = ConsoleSubscriber.init([])

    output =
      capture_io(fn ->
        ConsoleSubscriber.handle_info({:item_result, host, item, {:error, "timeout"}}, state)
      end)

    assert output =~ "\a"
    assert output =~ "timeout"
  end

  test "does not beep when an item result succeeds" do
    host = %Host{name: "gateway", address: "192.0.2.1", items: []}
    item = %Item{name: "ping", type: :icmp}
    {:ok, state} = ConsoleSubscriber.init([])

    output =
      capture_io(fn ->
        ConsoleSubscriber.handle_info({:item_result, host, item, {:ok, 1.23}}, state)
      end)

    refute output =~ "\a"
    assert output =~ "1.23 ms"
  end

  test "hides the cursor while the statistics view is shown" do
    {:ok, state} = ConsoleSubscriber.init([])

    {{:noreply, state}, enter} =
      with_io(fn -> ConsoleSubscriber.handle_cast(:toggle_view, state) end)

    {{:noreply, _state}, leave} =
      with_io(fn -> ConsoleSubscriber.handle_cast(:toggle_view, state) end)

    assert enter =~ "\e[?25l"
    assert leave =~ "\e[?25h"
  end

  test "coalesces statistics renders instead of redrawing on every result" do
    host = %Host{name: "gateway", address: "192.0.2.1", items: []}
    item = %Item{name: "ping", type: :icmp}
    {:ok, state} = ConsoleSubscriber.init([])
    state = %{state | mode: :stats}

    {state, output} =
      with_io(fn ->
        Enum.reduce(1..3, state, fn _, state ->
          {:noreply, state} =
            ConsoleSubscriber.handle_info({:item_result, host, item, {:ok, 1.23}}, state)

          state
        end)
      end)

    assert output == ""
    assert_receive :render_stats, 500
    refute_received :render_stats

    {{:noreply, state}, frame} =
      with_io(fn -> ConsoleSubscriber.handle_info(:render_stats, state) end)

    assert String.starts_with?(frame, "\e[H")
    assert String.ends_with?(frame, "\e[J")
    refute frame =~ "\e[2J"
    refute state.stats_dirty
    refute state.render_scheduled
  end

  test "skips a scheduled render when nothing changed" do
    {:ok, state} = ConsoleSubscriber.init([])
    state = %{state | mode: :stats, render_scheduled: true}

    output = capture_io(fn -> ConsoleSubscriber.handle_info(:render_stats, state) end)

    assert output == ""
  end
end
