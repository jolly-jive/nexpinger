defmodule NexPinger.Broadcaster do
  @moduledoc """
  Event hub that sends monitoring results to subscribers.
  """

  use GenServer

  alias NexPinger.{Host, Item}

  @type event :: {:ok, float()} | {:error, String.t()}
  @type subscriber :: pid() | atom()

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

  @spec subscribe(subscriber()) :: :ok | {:error, :not_found}
  def subscribe(subscriber) when is_pid(subscriber) do
    GenServer.cast(__MODULE__, {:subscribe, subscriber})
  end

  def subscribe(subscriber) when is_atom(subscriber) do
    case Process.whereis(subscriber) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(__MODULE__, {:subscribe, pid})
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{subscribers: []}}
  end

  @impl true
  def handle_cast({:subscribe, subscriber}, %{subscribers: subscribers} = state) do
    {:noreply, %{state | subscribers: Enum.uniq([subscriber | subscribers])}}
  end

  def handle_cast({:publish, host, item, event, timestamp}, %{subscribers: subscribers} = state) do
    Enum.each(subscribers, fn subscriber ->
      send(subscriber, {:item_result, host, item, event, timestamp})
    end)

    {:noreply, state}
  end
end
