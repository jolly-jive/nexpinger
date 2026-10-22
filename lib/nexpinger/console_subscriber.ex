defmodule NexPinger.ConsoleSubscriber do
  @moduledoc """
  Subscriber that prints results from the Broadcaster to the console.

  The CLI starts it under `NexPinger.SubscriberSupervisor` with the hosts, the stats options and
  `subscribe: true`, so a restarted subscriber gets its settings back and subscribes to the
  Broadcaster again. The statistics start over.

  If the terminal stops taking output (a selection in a Windows console, Ctrl+S, a stopped pipe),
  the Broadcaster drops results once 1000 wait. When output moves again, each target gets a
  `DROPPED` line, and the stats screen title shows the total: those results are not counted.
  """

  use GenServer

  alias NexPinger.{Broadcaster, Host, Item, ResultLine, Statistics, StatisticsView, TerminalInput}

  @default_stats_window 1000
  @default_stats_width 80
  @default_stats_height 24
  # Stats redraw interval (ms). Redraw on this timer, not per result.
  @stats_render_interval 100
  # Terminal size check interval (ms) while the stats screen is shown
  @size_check_interval 500

  # Stats screen uses the alternate screen buffer and hides the cursor
  @enter_stats_screen "\e[?1049h\e[?25l\e[2J\e[H"
  @leave_stats_screen "\e[?25h\e[?1049l"

  # Kept outside the process state: must be readable when this process is down
  @stats_view {__MODULE__, :stats_view}

  def leave_stats_screen, do: @leave_stats_screen

  @doc "True while the stats screen is shown."
  def stats_view?, do: :persistent_term.get(@stats_view, false)

  @doc """
  Options: `:hosts`, `:stats_window`, `:fixed_width` (80..120 keeps the stats screen width;
  nil follows the terminal), `:subscribe` (subscribe to the Broadcaster on start; default false).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def toggle_view, do: GenServer.cast(__MODULE__, :toggle_view)
  def scroll(direction), do: GenServer.cast(__MODULE__, {:scroll, direction})
  def end_stats_view, do: GenServer.call(__MODULE__, :end_stats_view)

  @impl true
  # `:stats_size` (test hook): 0-arity fun returning `{width, height}`
  def init(opts) do
    hosts = Keyword.get(opts, :hosts, [])

    # A restart while the stats screen was shown starts in the results view
    if stats_view?() do
      IO.write(@leave_stats_screen)
      :persistent_term.put(@stats_view, false)
    end

    if Keyword.get(opts, :subscribe, false) do
      Broadcaster.subscribe(self())
    end

    {:ok,
     %{
       statistics: Statistics.new(hosts, Keyword.get(opts, :stats_window, @default_stats_window)),
       stats_size: Keyword.get(opts, :stats_size, &TerminalInput.stats_size/0),
       fixed_width: Keyword.get(opts, :fixed_width),
       stats_width: @default_stats_width,
       stats_height: @default_stats_height,
       size_check: nil,
       widths: ResultLine.widths(hosts),
       mode: :results,
       offset: 0,
       dropped: 0,
       stats_dirty: false,
       render_scheduled: false
     }}
  end

  @impl true
  def handle_call(:end_stats_view, _from, %{mode: :stats} = state) do
    {:reply, :ok, leave_stats(state)}
  end

  def handle_call(:end_stats_view, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast(:toggle_view, %{mode: :results} = state) do
    IO.write(@enter_stats_screen)
    :persistent_term.put(@stats_view, true)
    state = state |> read_stats_size() |> schedule_size_check()
    state = render_stats(%{state | mode: :stats, offset: 0})
    {:noreply, state}
  end

  def handle_cast(:toggle_view, %{mode: :stats} = state) do
    {:noreply, leave_stats(state)}
  end

  def handle_cast({:scroll, direction}, %{mode: :stats} = state) do
    direction_offset = if direction == :down, do: 1, else: -1
    state = render_stats(clamp_offset(%{state | offset: state.offset + direction_offset}))
    {:noreply, state}
  end

  def handle_cast({:scroll, _direction}, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:item_result, %Host{} = host, %Item{} = item, {status, _} = result, timestamp},
        state
      )
      when status in [:ok, :error] do
    if status == :error, do: IO.write("\a")

    state = record_result(state, host, item, result)

    state =
      if state.mode == :stats do
        schedule_stats_render(state)
      else
        print_result(timestamp, host, item, result, state.widths)
        state
      end

    {:noreply, state}
  end

  def handle_info({:results_dropped, drops}, state) do
    IO.write("\a")
    state = %{state | dropped: state.dropped + (drops |> Enum.map(& &1.count) |> Enum.sum())}

    state =
      if state.mode == :stats do
        schedule_stats_render(state)
      else
        for drop <- drops do
          result = {:dropped, drop.count, drop.first_at}
          print_result(drop.last_at, drop.host, drop.item, result, state.widths)
        end

        state
      end

    {:noreply, state}
  end

  # A changed size redraws from a cleared screen, so nothing of the old layout stays.
  def handle_info({:check_size, ref}, %{mode: :stats, size_check: ref} = state) do
    size = {state.stats_width, state.stats_height}
    state = state |> read_stats_size() |> schedule_size_check()

    state =
      if {state.stats_width, state.stats_height} == size do
        state
      else
        IO.write("\e[2J")
        render_stats(clamp_offset(state))
      end

    {:noreply, state}
  end

  def handle_info({:check_size, _ref}, state), do: {:noreply, state}

  def handle_info(:render_stats, state) do
    state = %{state | render_scheduled: false}

    state =
      if state.mode == :stats and state.stats_dirty, do: render_stats(state), else: state

    {:noreply, state}
  end

  defp leave_stats(state) do
    IO.write(@leave_stats_screen)
    :persistent_term.put(@stats_view, false)
    %{state | mode: :results, size_check: nil}
  end

  defp read_stats_size(state) do
    {width, height} = state.stats_size.()
    %{state | stats_width: state.fixed_width || width, stats_height: height}
  end

  # The ref in the message drops a check scheduled before leaving and re-entering the view.
  defp schedule_size_check(state) do
    ref = make_ref()
    Process.send_after(self(), {:check_size, ref}, @size_check_interval)
    %{state | size_check: ref}
  end

  defp clamp_offset(state) do
    entry_count = length(Statistics.entries(state.statistics))
    max_offset = StatisticsView.max_offset(entry_count, state.stats_width, state.stats_height)
    %{state | offset: state.offset |> max(0) |> min(max_offset)}
  end

  defp record_result(state, host, item, result) do
    %{state | statistics: Statistics.record(state.statistics, host, item, result)}
  end

  defp schedule_stats_render(%{render_scheduled: true} = state), do: %{state | stats_dirty: true}

  defp schedule_stats_render(state) do
    Process.send_after(self(), :render_stats, @stats_render_interval)
    %{state | stats_dirty: true, render_scheduled: true}
  end

  # Some terminals (Windows) don't map "\n" to "\r\n" in raw mode, so write "\r\n".
  defp print_result(timestamp, host, item, result, widths) do
    IO.write([ResultLine.format(timestamp, host, item, result, widths, :console), "\r\n"])
  end

  # Clearing first causes flicker. Instead: cursor to top-left, overwrite,
  # clear line ends and the rest of the screen. One write.
  defp render_stats(state) do
    frame =
      state.statistics
      |> StatisticsView.render(state.stats_width, state.stats_height, state.offset, state.dropped)
      |> String.replace("\r\n", "\e[K\r\n")

    IO.write(["\e[H", frame, "\e[J"])
    %{state | stats_dirty: false}
  end
end
