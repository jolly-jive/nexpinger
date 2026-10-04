defmodule NexPinger.Runner do
  @moduledoc """
  Monitors one Item on a host.
  One process per Item; probes every interval.
  """

  use GenServer

  alias NexPinger.{Broadcaster, Host, Item, MacResolver, Prober}

  @type state :: %{
          host: Host.t(),
          item: Item.t(),
          interval: non_neg_integer()
        }

  @spec start_link({Host.t(), Item.t()}) :: GenServer.on_start()
  def start_link({%Host{} = host, %Item{} = item}) do
    GenServer.start_link(__MODULE__, {host, item}, name: via_name(host.name, item.name))
  end

  @spec probe(Host.t(), Item.t()) :: :ok
  def probe(%Host{} = host, %Item{} = item) do
    GenServer.cast(via_name(host.name, item.name), :probe)
  end

  @impl true
  def init({%Host{} = host, %Item{} = item}) do
    schedule_next(0)
    {:ok, %{host: host, item: item, interval: item.interval}}
  end

  @impl true
  def handle_info(:probe, %{host: host, item: item} = state) do
    # The IP is fixed at startup; only the MAC is looked up per probe
    result = Prober.probe(host.ip, item)
    host = %{host | mac_address: MacResolver.lookup(host.resolved)}
    Broadcaster.publish(host, item, result)
    schedule_next(state.interval)
    {:noreply, state}
  end

  defp schedule_next(interval) do
    Process.send_after(self(), :probe, interval)
  end

  defp via_name(host_name, item_name) do
    {:via, Registry, {NexPinger.MonitorRegistry, {host_name, item_name}}}
  end
end
