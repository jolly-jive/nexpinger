defmodule NexPinger.ConsoleSubscriberTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias NexPinger.{ConsoleSubscriber, Host, Item}

  @timestamp "2026-09-30 12:00:00.123"

  # Entering the stats view sets a global flag; a later init would see it
  setup do
    on_exit(fn -> :persistent_term.put({ConsoleSubscriber, :stats_view}, false) end)
  end

  test "beeps when an item result is an error" do
    host = %Host{name: "gateway", address: "192.0.2.1", items: []}
    item = %Item{name: "ping", type: :icmp}
    {:ok, state} = ConsoleSubscriber.init([])

    output =
      capture_io(fn ->
        ConsoleSubscriber.handle_info(
          {:item_result, host, item, {:error, "timeout"}, @timestamp},
          state
        )
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
        ConsoleSubscriber.handle_info({:item_result, host, item, {:ok, 1.23}, @timestamp}, state)
      end)

    refute output =~ "\a"
    assert output =~ "1.23 ms"
  end

  test "pads the columns to the widths set from the hosts" do
    ping = %Item{name: "ping", type: :icmp}
    https = %Item{name: "https", type: :tcp, port: 443}

    web = %Host{
      name: "web",
      address: "www.example.com",
      resolved: "203.0.113.10",
      items: [ping, https]
    }

    gateway = %Host{
      name: "gateway",
      address: "192.0.2.1",
      resolved: "192.0.2.1",
      on_link: true,
      items: [ping]
    }

    {:ok, state} = ConsoleSubscriber.init(hosts: [web, gateway])

    output =
      capture_io(fn ->
        ConsoleSubscriber.handle_info({:item_result, web, https, {:ok, 1.23}, @timestamp}, state)

        ConsoleSubscriber.handle_info(
          {:item_result, gateway, ping, {:error, "timeout"}, @timestamp},
          state
        )
      end)

    ok = IO.ANSI.green() <> "ok" <> IO.ANSI.reset()
    ng = IO.ANSI.red() <> "NG" <> IO.ANSI.reset()

    assert output =~ " 203.0.113.10 -      https 443/tcp #{ok}     1.23 ms  web\r\n"
    assert output =~ " 192.0.2.1    no-mac ping  icmp    #{ng} timeout      gateway\r\n"
    refute output =~ "www.example.com"
  end

  test "shows mac when the MAC address is found" do
    host = %Host{
      name: "gateway",
      address: "192.0.2.1",
      mac_address: "00:00:5e:00:53:01",
      items: []
    }

    item = %Item{name: "ping", type: :icmp}
    {:ok, state} = ConsoleSubscriber.init([])

    output =
      capture_io(fn ->
        ConsoleSubscriber.handle_info({:item_result, host, item, {:ok, 1.23}, @timestamp}, state)
      end)

    assert output =~ " 192.0.2.1 mac    ping icmp "
    refute output =~ "00:00:5e:00:53:01"
  end

  test "hides the cursor while the statistics view is shown" do
    {:ok, state} = ConsoleSubscriber.init(stats_size: fn -> {80, 24} end)

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
            ConsoleSubscriber.handle_info(
              {:item_result, host, item, {:ok, 1.23}, @timestamp},
              state
            )

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

  test "reads the terminal size when the statistics view opens" do
    {:ok, state} = ConsoleSubscriber.init(stats_size: fn -> {100, 30} end)

    {{:noreply, state}, frame} =
      with_io(fn -> ConsoleSubscriber.handle_cast(:toggle_view, state) end)

    assert {state.stats_width, state.stats_height} == {100, 30}
    assert frame =~ String.duplicate("-", 100) <> "\e[K\r\n"
    assert_receive {:check_size, ref}, 1000
    assert ref == state.size_check
  end

  test "redraws from a cleared screen when the terminal size changes" do
    hosts =
      for index <- 1..30 do
        %Host{
          name: "host-#{index}",
          address: "192.0.2.1",
          items: [%Item{name: "ping", type: :icmp}]
        }
      end

    {:ok, state} = ConsoleSubscriber.init(hosts: hosts, stats_size: fn -> {120, 40} end)

    ref = make_ref()

    state = %{
      state
      | mode: :stats,
        size_check: ref,
        stats_width: 80,
        stats_height: 10,
        offset: 25
    }

    {{:noreply, state}, frame} =
      with_io(fn -> ConsoleSubscriber.handle_info({:check_size, ref}, state) end)

    assert {state.stats_width, state.stats_height} == {120, 40}
    assert state.offset == 0
    assert String.starts_with?(frame, "\e[2J\e[H")
    assert frame =~ String.duplicate("-", 120)
    assert state.size_check != ref
    assert_receive {:check_size, new_ref}, 1000
    assert new_ref == state.size_check
  end

  test "keeps a fixed width and skips redraws while the size stays the same" do
    {:ok, state} = ConsoleSubscriber.init(fixed_width: 80, stats_size: fn -> {120, 24} end)

    ref = make_ref()
    state = %{state | mode: :stats, size_check: ref}

    {{:noreply, state}, output} =
      with_io(fn -> ConsoleSubscriber.handle_info({:check_size, ref}, state) end)

    assert output == ""
    assert state.stats_width == 80
  end

  test "ignores a size check scheduled before the statistics view was left" do
    {:ok, state} = ConsoleSubscriber.init(stats_size: fn -> flunk("size read") end)

    assert {:noreply, ^state} = ConsoleSubscriber.handle_info({:check_size, make_ref()}, state)

    state = %{state | mode: :stats, size_check: make_ref()}
    assert {:noreply, ^state} = ConsoleSubscriber.handle_info({:check_size, make_ref()}, state)
  end

  test "leaves a stats screen left over from before a restart" do
    :persistent_term.put({ConsoleSubscriber, :stats_view}, true)

    {{:ok, state}, output} = with_io(fn -> ConsoleSubscriber.init([]) end)

    assert output == ConsoleSubscriber.leave_stats_screen()
    refute ConsoleSubscriber.stats_view?()
    assert state.mode == :results
  end

  describe "under a supervisor" do
    test "gets its settings back and subscribes again after a restart" do
      host = %Host{
        name: "gateway",
        address: "192.0.2.1",
        resolved: "192.0.2.1",
        items: [%Item{name: "ping", type: :icmp}]
      }

      supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, pid} =
        DynamicSupervisor.start_child(
          supervisor,
          {ConsoleSubscriber, hosts: [host], stats_window: 50, fixed_width: 100, subscribe: true}
        )

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      new_pid = wait_for_restart(supervisor, pid)
      state = :sys.get_state(new_pid)

      assert state.fixed_width == 100
      assert state.statistics.window == 50
      assert [%{host: %Host{name: "gateway"}}] = NexPinger.Statistics.entries(state.statistics)
      assert state.widths.ip == String.length("192.0.2.1")

      assert Map.has_key?(:sys.get_state(NexPinger.Broadcaster).subscribers, new_pid)
    end
  end

  defp wait_for_restart(supervisor, old_pid, tries \\ 100) do
    case DynamicSupervisor.which_children(supervisor) do
      [{_, pid, _, _}] when is_pid(pid) and pid != old_pid ->
        pid

      _not_yet when tries > 0 ->
        Process.sleep(10)
        wait_for_restart(supervisor, old_pid, tries - 1)
    end
  end
end
