defmodule NexPinger.ConsoleSubscriber do
  @moduledoc """
  Broadcaster 経由で届いた監視結果をコンソールに出力する subscriber.
  """

  use GenServer

  alias NexPinger.{Host, Item, Statistics, StatisticsView}

  @default_stats_window 1000
  @default_stats_width 80
  @default_stats_height 24

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
       mode: :results,
       offset: 0
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
         stats_height: stats_height
     }}
  end

  def handle_call(:end_stats_view, _from, %{mode: :stats} = state) do
    IO.write("\e[?1049l")
    {:reply, :ok, %{state | mode: :results}}
  end

  def handle_call(:end_stats_view, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast(:toggle_view, %{mode: :results} = state) do
    IO.write("\e[?1049h\e[2J\e[H")
    state = %{state | mode: :stats, offset: 0}
    render_stats(state)
    {:noreply, state}
  end

  def handle_cast(:toggle_view, %{mode: :stats} = state) do
    IO.write("\e[?1049l")
    {:noreply, %{state | mode: :results}}
  end

  def handle_cast({:scroll, direction}, %{mode: :stats} = state) do
    direction_offset = if direction == :down, do: 1, else: -1
    entry_count = length(Statistics.entries(state.statistics))
    max_offset = StatisticsView.max_offset(entry_count, state.stats_width, state.stats_height)
    offset = min(max(state.offset + direction_offset, 0), max_offset)
    state = %{state | offset: offset}
    render_stats(state)
    {:noreply, state}
  end

  def handle_cast({:scroll, _direction}, state), do: {:noreply, state}

  @impl true
  def handle_info({:item_result, %Host{} = host, %Item{} = item, {:ok, rtt_ms}}, state) do
    state = record_result(state, host, item, {:ok, rtt_ms})

    if state.mode == :stats do
      render_stats(state)
    else
      print_result(host, item, {:ok, rtt_ms})
    end

    {:noreply, state}
  end

  def handle_info({:item_result, %Host{} = host, %Item{} = item, {:error, reason}}, state) do
    IO.write("\a")

    state = record_result(state, host, item, {:error, reason})

    if state.mode == :stats do
      render_stats(state)
    else
      print_result(host, item, {:error, reason})
    end

    {:noreply, state}
  end

  defp record_result(state, host, item, result) do
    %{state | statistics: Statistics.record(state.statistics, host, item, result)}
  end

  # raw mode では "\n" が "\r\n" に変換されない端末（Windows）があるため、"\r\n" を明示する。
  defp print_result(host, item, {:ok, rtt_ms}) do
    IO.write([
      timestamp(),
      " | ",
      format_label(host, item),
      status_tag(:ok),
      " ",
      :io_lib.format("~7.2f ms", [rtt_ms]),
      "\r\n"
    ])
  end

  defp print_result(host, item, {:error, reason}) do
    IO.write([
      timestamp(),
      " | ",
      format_label(host, item),
      status_tag(:ng),
      " ",
      reason,
      "\r\n"
    ])
  end

  defp render_stats(state) do
    IO.write("\e[2J\e[H")

    IO.write(
      StatisticsView.render(state.statistics, state.stats_width, state.stats_height, state.offset)
    )
  end

  defp format_label(%Host{name: name, address: address} = host, %Item{
         name: item_name,
         type: type,
         port: port
       }) do
    type_str = type |> Atom.to_string() |> String.upcase() |> String.pad_trailing(4)
    item_label = if port, do: "#{item_name}:#{port}", else: item_name

    [
      String.pad_trailing("#{name}/#{item_label}", 24),
      "(",
      String.pad_trailing(address, 15),
      ") ",
      mac_label(host),
      type_str,
      " "
    ]
  end

  defp mac_label(%Host{mac_address: nil}), do: String.duplicate(" ", 18)
  defp mac_label(%Host{mac_address: mac}), do: mac <> " "

  defp status_tag(:ok), do: IO.ANSI.green() <> "OK " <> IO.ANSI.reset()
  defp status_tag(:ng), do: IO.ANSI.red() <> "NG " <> IO.ANSI.reset()

  defp timestamp do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:millisecond)
    |> NaiveDateTime.to_string()
  end
end
