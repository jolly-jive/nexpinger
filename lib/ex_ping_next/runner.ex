defmodule ExPingNext.Runner do
  @moduledoc """
  1台のホストを監視するアクター。
  監視対象ごとに独立したプロセスが interval ごとに probe を実行する。
  """

  use GenServer

  alias ExPingNext.{Broadcaster, Host, MacResolver, Prober}

  @type state :: %{
          host: Host.t(),
          interval: non_neg_integer()
        }

  @spec start_link(Host.t()) :: GenServer.on_start()
  def start_link(%Host{} = host) do
    GenServer.start_link(__MODULE__, host, name: via_name(host.name))
  end

  @spec probe(Host.t()) :: :ok
  def probe(%Host{} = host) do
    GenServer.cast(via_name(host.name), :probe)
  end

  @impl true
  def init(%Host{} = host) do
    schedule_next(0)
    {:ok, %{host: host, interval: host.interval}}
  end

  @impl true
  def handle_info(:probe, %{host: host} = state) do
    result = Prober.probe(host)
    host_with_mac = %{host | mac_address: MacResolver.lookup(host.address)}
    Broadcaster.publish(host_with_mac, result)
    schedule_next(state.interval)
    {:noreply, state}
  end

  defp schedule_next(interval) do
    Process.send_after(self(), :probe, interval)
  end

  defp via_name(name) do
    {:via, Registry, {ExPingNext.MonitorRegistry, name}}
  end

end
