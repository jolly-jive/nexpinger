defmodule NexPinger.MacResolver do
  @moduledoc """
  Looks up the MAC address of an IP in the OS neighbor table (ARP / NDP).
  Only on-link hosts are in the table, so others get nil.
    * Linux: `ip neigh show <ip>` (IPv4 and IPv6)
    * Windows: the helper (`NexPinger.IcmpHelper.mac/1`), else `arp -a` (IPv4 only)
    * Other: nil

  Results, nil included, are cached per IP for 15 s. Items of a host share one lookup,
  and off-link hosts don't run a command on every probe. 15 s is the shortest
  REACHABLE time of Linux and Windows, so the cache adds little to the OS's own delay.
  """

  use GenServer

  alias NexPinger.{IcmpHelper, Resolver}

  @table __MODULE__
  @ttl_ms 15_000

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  @spec lookup(String.t()) :: String.t() | nil
  def lookup(ip), do: cached(ip, System.monotonic_time(:millisecond), &neighbor_mac/1)

  @doc false
  @spec cached(String.t(), integer(), (String.t() -> String.t() | nil)) :: String.t() | nil
  def cached(ip, now, fetch) do
    case :ets.lookup(@table, ip) do
      [{^ip, mac, fetched_at}] when now - fetched_at < @ttl_ms ->
        mac

      _ ->
        mac = fetch.(ip)
        :ets.insert(@table, {ip, mac, now})
        mac
    end
  end

  defp neighbor_mac(ip) do
    case :os.type() do
      {:unix, :linux} -> ip_neigh(ip)
      {:win32, _} -> helper_mac(ip)
      _ -> nil
    end
  end

  defp ip_neigh(ip) do
    case System.cmd("ip", ["neigh", "show", ip], stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
      {output, 0} -> parse_ip_neigh(output)
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp helper_mac(ip) do
    case IcmpHelper.mac(ip) do
      {:ok, mac} -> mac
      {:error, :unavailable} -> arp(ip)
      {:error, _reason} -> nil
    end
  end

  defp arp(ip) do
    with :ipv4 <- Resolver.literal_family(ip),
         {output, 0} <- System.cmd("arp", ["-a", ip], stderr_to_stdout: true) do
      parse_arp(output)
    else
      _ -> nil
    end
  rescue
    _error -> nil
  end

  # FAILED / INCOMPLETE entries have no lladdr. STALE ones do, and are used.
  @doc false
  @spec parse_ip_neigh(String.t()) :: String.t() | nil
  def parse_ip_neigh(output) do
    case Regex.run(~r/\blladdr\s+([0-9a-f]{2}(?::[0-9a-f]{2}){5})\b/i, output) do
      [_, mac] -> String.downcase(mac)
      nil -> nil
    end
  end

  @doc false
  @spec parse_arp(String.t()) :: String.t() | nil
  def parse_arp(output) do
    case Regex.run(~r/\b([0-9a-f]{2}(?:[:-][0-9a-f]{2}){5})\b/i, output) do
      [_, mac] -> mac |> String.replace("-", ":") |> String.downcase()
      nil -> nil
    end
  end
end
