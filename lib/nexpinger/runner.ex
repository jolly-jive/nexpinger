defmodule NexPinger.Runner do
  @moduledoc """
  Monitors one Item on a host.
  One process per Item; probes every interval.

  Probes start on a fixed schedule (start to start), so the probe time does not
  add to the interval. A probe that runs past the next start skips the missed
  starts instead of firing them in a burst.
  """

  use GenServer

  alias NexPinger.{Broadcaster, Host, Item, MacResolver, Prober, Timestamp}

  @type state :: %{
          host: Host.t(),
          item: Item.t(),
          interval: pos_integer(),
          next_at: integer()
        }

  @spec start_link({Host.t(), Item.t()}) :: GenServer.on_start()
  def start_link({%Host{} = host, %Item{} = item}) do
    GenServer.start_link(__MODULE__, {host, item}, name: via_name(host.name, item.name))
  end

  @impl true
  def init({%Host{} = host, %Item{} = item}) do
    now = now()
    schedule_at(now)
    {:ok, %{host: host, item: item, interval: item.interval, next_at: now}}
  end

  @impl true
  def handle_info(:probe, %{host: host, item: item} = state) do
    # The IP is fixed at startup; only the MAC is looked up per probe
    result = safe_probe(host.ip, item)
    timestamp = Timestamp.now()
    host = %{host | mac_address: safe_mac(host)}
    Broadcaster.publish(host, item, result, timestamp)
    next_at = next_start(state.next_at, state.interval, now())
    schedule_at(next_at)
    {:noreply, %{state | next_at: next_at}}
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

  # Off-link hosts have no neighbor entry, so they are not looked up
  defp safe_mac(%Host{on_link: false}), do: nil

  defp safe_mac(%Host{resolved: ip}) do
    MacResolver.lookup(ip)
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  # The result is one line on the console
  defp first_line(message), do: message |> String.split("\n", parts: 2) |> hd()

  # The first start at or after `now` on the grid `last_at + n * interval` (n >= 1)
  @doc false
  @spec next_start(integer(), pos_integer(), integer()) :: integer()
  def next_start(last_at, interval, now) do
    missed = div(max(now - last_at, 0) + interval - 1, interval)
    last_at + max(missed, 1) * interval
  end

  defp schedule_at(time) do
    Process.send_after(self(), :probe, time, abs: true)
  end

  # Process.send_after/4 with abs: true takes this clock
  defp now, do: System.monotonic_time(:millisecond)

  defp via_name(host_name, item_name) do
    {:via, Registry, {NexPinger.MonitorRegistry, {host_name, item_name}}}
  end
end
