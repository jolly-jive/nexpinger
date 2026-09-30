defmodule NexPinger.Broadcaster do
  @moduledoc """
  監視結果を複数の subscriber へ配信するイベントハブ。
  """

  use GenServer

  alias NexPinger.{Host, Item}

  @type event :: {:ok, float()} | {:error, String.t()}
  @type subscriber :: pid() | atom()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec publish(Host.t(), Item.t(), event()) :: :ok
  def publish(%Host{} = host, %Item{} = item, event) do
    GenServer.cast(__MODULE__, {:publish, host, item, event})
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

  def handle_cast({:publish, host, item, event}, %{subscribers: subscribers} = state) do
    Enum.each(subscribers, fn subscriber ->
      send(subscriber, {:item_result, host, item, event})
    end)

    {:noreply, state}
  end
end
