defmodule NexPinger.AddressLabel do
  @moduledoc """
  The address column of the text output.
  A host name is shown with its resolved IP: `name=ip`.

  On the console the column has a fixed width, set at startup from the hosts.
  Text that does not fit is cut, keeping the IP:
    1. cut the name from the right (`www.exa..=192.0.2.1`)
    2. drop the name
    3. cut the IP from the left, keeping the interface ID (`..:c3ff:fed4:e5f6`)
  ASCII only: `…` is ambiguous width and may take 2 columns.
  """

  alias NexPinger.{Host, Resolver}

  @min_width 15
  @max_width 24
  @max_ip_length %{ipv4: 15, ipv6: 39, auto: 39}
  # Shortest cut name worth showing: 3 chars + ".."
  @min_cut_name 5

  @spec min_width() :: pos_integer()
  def min_width, do: @min_width

  @doc """
  The column width for these hosts.
  """
  @spec width([Host.t()]) :: pos_integer()
  def width(hosts) do
    hosts
    |> Enum.map(&max_length/1)
    |> Enum.max(fn -> 0 end)
    |> max(@min_width)
    |> min(@max_width)
  end

  defp max_length(%Host{address: address, family: family}) do
    if Resolver.literal_family(address),
      do: String.length(address),
      else: String.length(address) + 1 + @max_ip_length[family]
  end

  @doc """
  The whole label, not cut.
  """
  @spec full(Host.t()) :: String.t()
  def full(%Host{} = host) do
    case name_and_ip(host) do
      {name, ip} -> name <> "=" <> ip
      nil -> host.address
    end
  end

  @doc """
  The label cut to fit `width`, padded to it.
  """
  @spec fit(Host.t(), pos_integer()) :: String.t()
  def fit(%Host{} = host, width) do
    label =
      case name_and_ip(host) do
        {name, ip} -> fit_name_and_ip(name, ip, width)
        nil -> cut_left(host.address, width)
      end

    String.pad_trailing(label, width)
  end

  defp fit_name_and_ip(name, ip, width) do
    room = width - String.length(ip) - 1

    cond do
      String.length(name) <= room -> name <> "=" <> ip
      room >= @min_cut_name -> cut_right(name, room) <> "=" <> ip
      true -> cut_left(ip, width)
    end
  end

  defp name_and_ip(%Host{address: address, resolved: resolved}) do
    if resolved && Resolver.literal_family(address) == nil, do: {address, resolved}
  end

  defp cut_right(text, width), do: String.slice(text, 0, width - 2) <> ".."

  defp cut_left(text, width) do
    if String.length(text) <= width,
      do: text,
      else: ".." <> String.slice(text, -(width - 2)..-1//1)
  end
end
