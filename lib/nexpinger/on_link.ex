defmodule NexPinger.OnLink do
  @moduledoc """
  Tells whether an IP is on-link: in the subnet of one of this host's interfaces.
  Loopback interfaces and this host's own addresses don't count; they have no
  neighbor entry.

  The subnet is taken from the interface's address and netmask. An IPv6 on-link
  prefix that differs from it (e.g. a /128 address) is not seen.
  """

  @type network :: {address :: :inet.ip_address(), netmask :: :inet.ip_address()}

  @doc """
  The networks of this host's interfaces.
  """
  @spec networks() :: [network()]
  def networks do
    case :inet.getifaddrs() do
      {:ok, interfaces} -> Enum.flat_map(interfaces, fn {_name, opts} -> networks(opts) end)
      {:error, _reason} -> []
    end
  end

  @doc false
  @spec networks(keyword()) :: [network()]
  def networks(opts) do
    if :loopback in Keyword.get(opts, :flags, []), do: [], else: pairs(opts)
  end

  # Each addr is followed by its netmask
  defp pairs([{:addr, address}, {:netmask, netmask} | rest]),
    do: [{address, netmask} | pairs(rest)]

  defp pairs([_ | rest]), do: pairs(rest)
  defp pairs([]), do: []

  @spec on_link?(:inet.ip_address() | nil, [network()]) :: boolean()
  def on_link?(ip, networks) do
    not Enum.any?(networks, fn {address, _netmask} -> address == ip end) and
      Enum.any?(networks, fn {address, netmask} -> same_network?(ip, address, netmask) end)
  end

  defp same_network?(ip, address, netmask)
       when tuple_size(ip) == tuple_size(address) and tuple_size(ip) == tuple_size(netmask) do
    masked(ip, netmask) == masked(address, netmask)
  end

  defp same_network?(_ip, _address, _netmask), do: false

  defp masked(ip, netmask) do
    Enum.zip_with(Tuple.to_list(ip), Tuple.to_list(netmask), &Bitwise.band/2)
  end
end
