defmodule NexPinger.Resolver do
  @moduledoc """
  Resolves a host address to an IP of the host's family.
    * `:ipv4` / `:ipv6`: an IP literal of that family, or the A / AAAA record
    * `:auto`: any IP literal, or the A record, else the AAAA record
  """

  @type family :: :ipv4 | :ipv6 | :auto

  @spec resolve(String.t(), family()) :: {:ok, :inet.ip_address()} | {:error, String.t()}
  def resolve(address, family) do
    charlist = to_charlist(address)

    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        if family in [:auto, ip_family(ip)],
          do: {:ok, ip},
          else: {:error, "not an #{family_name(family)} address"}

      {:error, _} ->
        lookup(charlist, family)
    end
  end

  defp lookup(charlist, :auto) do
    with {:error, _} <- lookup(charlist, :ipv4), do: lookup(charlist, :ipv6)
  end

  defp lookup(charlist, family) do
    case :inet.getaddr(charlist, socket_family(family)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, "unknown host"}
    end
  end

  @doc """
  Returns the IP literal's family, or nil for a host name.
  """
  @spec literal_family(String.t()) :: :ipv4 | :ipv6 | nil
  def literal_family(address) do
    case :inet.parse_address(to_charlist(address)) do
      {:ok, ip} -> ip_family(ip)
      {:error, _} -> nil
    end
  end

  @spec ip_family(:inet.ip_address()) :: :ipv4 | :ipv6
  def ip_family(ip) when tuple_size(ip) == 4, do: :ipv4
  def ip_family(ip) when tuple_size(ip) == 8, do: :ipv6

  @doc """
  The family atom for :socket, :gen_tcp and :gen_udp.
  """
  @spec socket_family(:inet.ip_address() | :ipv4 | :ipv6) :: :inet | :inet6
  def socket_family(:ipv4), do: :inet
  def socket_family(:ipv6), do: :inet6
  def socket_family(ip) when is_tuple(ip), do: socket_family(ip_family(ip))

  @spec family_name(family()) :: String.t()
  def family_name(:ipv4), do: "IPv4"
  def family_name(:ipv6), do: "IPv6"
  def family_name(:auto), do: "auto"

  @spec to_string(:inet.ip_address()) :: String.t()
  def to_string(ip), do: ip |> :inet.ntoa() |> List.to_string()
end
