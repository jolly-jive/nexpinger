defmodule NexPinger.Broadcaster do
  @moduledoc """
  Event hub that sends monitoring results to subscribers.

  Subscribers are monitored and dropped when they exit. A restarted subscriber has a new pid,
  so it subscribes again itself (see `NexPinger.FileSubscriber` and `NexPinger.ConsoleSubscriber`).

  A subscriber that falls behind (a blocked terminal, a stalled network share) would grow its
  mailbox without bound. So each subscriber has a cap (`:max_queue`): while its mailbox holds
  that many messages, its results are dropped and counted per target. Once the mailbox is down
  to half the cap, it first gets `{:results_dropped, [dropped()]}`, then the results again.
  The other subscribers and the probes are not held up.
  """

  use GenServer

  alias NexPinger.{Host, Item}

  @type event :: {:ok, float()} | {:error, String.t()}
  @type subscriber :: pid() | atom()
  @type dropped :: %{
          host: Host.t(),
          item: Item.t(),
          count: pos_integer(),
          first_at: String.t(),
          last_at: String.t()
        }

  @default_max_queue 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sends `{:item_result, host, item, event, timestamp}` to every subscriber. The timestamp is
  when the result was taken, so a subscriber that handles it late still shows that time.
  """
  @spec publish(Host.t(), Item.t(), event(), String.t()) :: :ok
  def publish(%Host{} = host, %Item{} = item, event, timestamp) when is_binary(timestamp) do
    GenServer.cast(__MODULE__, {:publish, host, item, event, timestamp})
  end

  @doc """
  Options: `:max_queue` (mailbox size at which results are dropped; default #{@default_max_queue}).
  Subscribing again keeps the first options.
  """
  @spec subscribe(subscriber(), keyword()) :: :ok | {:error, :not_found}
  def subscribe(subscriber, opts \\ [])

  def subscribe(subscriber, opts) when is_pid(subscriber) do
    max_queue = Keyword.get(opts, :max_queue, @default_max_queue)

    unless is_integer(max_queue) and max_queue > 0 do
      raise ArgumentError, "invalid max_queue: #{inspect(max_queue)}"
    end

    GenServer.cast(__MODULE__, {:subscribe, subscriber, max_queue})
  end

  def subscribe(subscriber, opts) when is_atom(subscriber) do
    case Process.whereis(subscriber) do
      nil -> {:error, :not_found}
      pid -> subscribe(pid, opts)
    end
  end

  @impl true
  def init(_opts) do
    # pid => %{ref, max_queue, dropped: %{{host name, item name} => dropped()}}
    {:ok, %{subscribers: %{}}}
  end

  @impl true
  def handle_cast({:subscribe, pid, max_queue}, %{subscribers: subscribers} = state) do
    if Map.has_key?(subscribers, pid) do
      {:noreply, state}
    else
      subscriber = %{ref: Process.monitor(pid), max_queue: max_queue, dropped: %{}}
      {:noreply, %{state | subscribers: Map.put(subscribers, pid, subscriber)}}
    end
  end

  def handle_cast({:publish, host, item, event, timestamp}, %{subscribers: subscribers} = state) do
    message = {:item_result, host, item, event, timestamp}

    subscribers =
      Map.new(subscribers, fn {pid, subscriber} -> {pid, deliver(pid, subscriber, message)} end)

    {:noreply, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{subscribers: subscribers} = state) do
    case subscribers do
      %{^pid => %{ref: ^ref}} -> {:noreply, %{state | subscribers: Map.delete(subscribers, pid)}}
      _other -> {:noreply, state}
    end
  end

  defp deliver(pid, subscriber, {:item_result, host, item, _event, timestamp} = message) do
    send_below = send_below(subscriber)

    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} when length < send_below ->
        subscriber = send_dropped(pid, subscriber)
        send(pid, message)
        subscriber

      {:message_queue_len, _length} ->
        record_drop(subscriber, host, item, timestamp)

      # Exited; its :DOWN removes it
      nil ->
        subscriber
    end
  end

  # Once dropping, wait for half the cap: a subscriber that stays near the cap gets one
  # notice per stall, not one every few results
  defp send_below(%{dropped: dropped, max_queue: max_queue}) when dropped == %{}, do: max_queue
  defp send_below(%{max_queue: max_queue}), do: max(div(max_queue, 2), 1)

  defp record_drop(subscriber, host, item, timestamp) do
    dropped =
      Map.update(
        subscriber.dropped,
        {host.name, item.name},
        %{host: host, item: item, count: 1, first_at: timestamp, last_at: timestamp},
        # The host carries the MAC address of the latest attempt
        &%{&1 | host: host, count: &1.count + 1, last_at: timestamp}
      )

    %{subscriber | dropped: dropped}
  end

  defp send_dropped(_pid, %{dropped: dropped} = subscriber) when dropped == %{}, do: subscriber

  defp send_dropped(pid, subscriber) do
    send(
      pid,
      {:results_dropped, subscriber.dropped |> Map.values() |> Enum.sort_by(& &1.first_at)}
    )

    %{subscriber | dropped: %{}}
  end
end
