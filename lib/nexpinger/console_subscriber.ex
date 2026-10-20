defmodule NexPinger.ConsoleSubscriber do
  @moduledoc """
  Subscriber that prints results from the Broadcaster to the console.
  """

  use GenServer

  alias NexPinger.{Host, Item, ResultLine, Statistics, StatisticsView, TerminalInput, Timestamp}

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

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sets the hosts and the stats options. `fixed_width` (80..120) keeps the stats
  screen width; with nil it follows the terminal.
  """
  def configure(hosts, stats_window, fixed_width \\ nil) do
    GenServer.call(__MODULE__, {:configure, hosts, stats_window, fixed_width})
  end

  def toggle_view, do: GenServer.cast(__MODULE__, :toggle_view)
  def scroll(direction), do: GenServer.cast(__MODULE__, {:scroll, direction})
  def end_stats_view, do: GenServer.call(__MODULE__, :end_stats_view)

  @impl true
  # `:stats_size` (test hook): 0-arity fun returning `{width, height}`
  def init(opts) do
    {:ok,
     %{
       statistics: Statistics.new([], @default_stats_window),
       stats_size: Keyword.get(opts, :stats_size, &TerminalInput.stats_size/0),
       fixed_width: nil,
       stats_width: @default_stats_width,
       stats_height: @default_stats_height,
       size_check: nil,
       widths: ResultLine.widths([]),
       mode: :results,
       offset: 0,
       stats_dirty: false,
       render_scheduled: false
     }}
  end

  @impl true
  def handle_call({:configure, hosts, stats_window, fixed_width}, _from, state) do
    statistics = Statistics.new(hosts, stats_window)

    {:reply, :ok,
     %{
       state
       | statistics: statistics,
         fixed_width: fixed_width,
         widths: ResultLine.widths(hosts)
     }}
  end

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
