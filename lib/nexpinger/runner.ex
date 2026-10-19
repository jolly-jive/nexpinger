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
    result = safe_probe(host.ip, item)
    host = %{host | mac_address: safe_mac(host.resolved)}
    Broadcaster.publish(host, item, result)
    schedule_next(state.interval)
    {:noreply, state}
  end

  # A crash would restart the Runner; repeated crashes exhaust MonitorSupervisor and
  # stop every monitor. So an unexpected failure is shown as an NG result instead.
  defp safe_probe(ip, item) do
    Prober.probe(ip, item)
  rescue
    e -> {:error, first_line(Exception.message(e))}
  catch
    kind, reason -> {:error, first_line(Exception.format_banner(kind, reason))}
  end

  defp safe_mac(ip) do
    MacResolver.lookup(ip)
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  # The result is one line on the console
  defp first_line(message), do: message |> String.split("\n", parts: 2) |> hd()

  defp schedule_next(interval) do
    Process.send_after(self(), :probe, interval)
  end

  defp via_name(host_name, item_name) do
    {:via, Registry, {NexPinger.MonitorRegistry, {host_name, item_name}}}
  end
end
