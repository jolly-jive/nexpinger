defmodule NexPinger.ConsoleSubscriber do
  @moduledoc """
  Subscriber that prints results from the Broadcaster to the console.
  """

  use GenServer

  alias NexPinger.{Host, Item, ResultLine, Statistics, StatisticsView, Timestamp}

  @default_stats_window 1000
  @default_stats_width 80
  @default_stats_height 24
  # Stats redraw interval (ms). Redraw on this timer, not per result.
  @stats_render_interval 100

  # Stats screen uses the alternate screen buffer and hides the cursor
  @enter_stats_screen "\e[?1049h\e[?25l\e[2J\e[H"
  @leave_stats_screen "\e[?25h\e[?1049l"

  # Kept outside the process state: must be readable when this process is down
  @stats_view {__MODULE__, :stats_view}

  def leave_stats_screen, do: @leave_stats_screen

  @doc "True while the stats screen is shown."
  def stats_view?, do: :persistent_term.get(@stats_view, false)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def configure(hosts, stats_window, stats_width, stats_height \\ @default_stats_height) do
    GenServer.call(__MODULE__, {:configure, hosts, stats_window, stats_width, stats_height})
  end

  def toggle_view, do: GenServer.cast(__MODULE__, :toggle_view)
  def scroll(direction), do: GenServer.cast(__MODULE__, {:scroll, direction})
  def end_stats_view, do: GenServer.call(__MODULE__, :end_stats_view)

  @impl true
  def init(_opts) do
    {:ok,
     %{
       statistics: Statistics.new([], @default_stats_window),
       stats_width: @default_stats_width,
       stats_height: @default_stats_height,
       widths: ResultLine.widths([]),
       mode: :results,
       offset: 0,
       stats_dirty: false,
       render_scheduled: false
     }}
  end

  @impl true
  def handle_call({:configure, hosts, stats_window, stats_width, stats_height}, _from, state) do
    statistics = Statistics.new(hosts, stats_window)

    {:reply, :ok,
     %{
       state
       | statistics: statistics,
         stats_width: stats_width,
         stats_height: stats_height,
         widths: ResultLine.widths(hosts)
     }}
  end

  def handle_call(:end_stats_view, _from, %{mode: :stats} = state) do
    IO.write(@leave_stats_screen)
    :persistent_term.put(@stats_view, false)
    {:reply, :ok, %{state | mode: :results}}
  end

  def handle_call(:end_stats_view, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast(:toggle_view, %{mode: :results} = state) do
    IO.write(@enter_stats_screen)
    :persistent_term.put(@stats_view, true)
    state = render_stats(%{state | mode: :stats, offset: 0})
    {:noreply, state}
  end

  def handle_cast(:toggle_view, %{mode: :stats} = state) do
    IO.write(@leave_stats_screen)
    :persistent_term.put(@stats_view, false)
    {:noreply, %{state | mode: :results}}
  end

  def handle_cast({:scroll, direction}, %{mode: :stats} = state) do
    direction_offset = if direction == :down, do: 1, else: -1
    entry_count = length(Statistics.entries(state.statistics))
    max_offset = StatisticsView.max_offset(entry_count, state.stats_width, state.stats_height)
    offset = min(max(state.offset + direction_offset, 0), max_offset)
    state = render_stats(%{state | offset: offset})
    {:noreply, state}
  end

  def handle_cast({:scroll, _direction}, state), do: {:noreply, state}

  @impl true
  def handle_info({:item_result, %Host{} = host, %Item{} = item, {:ok, rtt_ms}}, state) do
    state = record_result(state, host, item, {:ok, rtt_ms})

    state =
      if state.mode == :stats do
        schedule_stats_render(state)
      else
        print_result(host, item, {:ok, rtt_ms}, state.widths)
        state
      end

    {:noreply, state}
  end

  def handle_info({:item_result, %Host{} = host, %Item{} = item, {:error, reason}}, state) do
    IO.write("\a")

    state = record_result(state, host, item, {:error, reason})

    state =
      if state.mode == :stats do
        schedule_stats_render(state)
      else
        print_result(host, item, {:error, reason}, state.widths)
        state
      end

    {:noreply, state}
  end

  def handle_info(:render_stats, state) do
    state = %{state | render_scheduled: false}

    state =
      if state.mode == :stats and state.stats_dirty, do: render_stats(state), else: state

    {:noreply, state}
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
  defp print_result(host, item, result, widths) do
    IO.write([ResultLine.format(Timestamp.now(), host, item, result, widths, :console), "\r\n"])
  end

  # Clearing first causes flicker. Instead: cursor to top-left, overwrite,
  # clear line ends and the rest of the screen. One write.
  defp render_stats(state) do
    frame =
      state.statistics
      |> StatisticsView.render(state.stats_width, state.stats_height, state.offset)
      |> String.replace("\r\n", "\e[K\r\n")

    IO.write(["\e[H", frame, "\e[J"])
    %{state | stats_dirty: false}
  end
end
