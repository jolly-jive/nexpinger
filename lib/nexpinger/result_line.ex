defmodule NexPinger.ResultLine do
  @moduledoc """
  One result as a line of text, for the console and the text log file.
  Columns: time, IP, MAC, item, port/protocol, ok|NG, RTT or reason, host name.

  The MAC column:
    * `mac` (console) or the MAC address (file): found in the neighbor table
    * `no-mac`: on-link, but not found
    * `-`: off-link

  The IP, item and port columns are as wide as the longest value of the hosts,
  so nothing is cut. The host name comes last: its length varies most.
  """

  alias NexPinger.{Host, Item}

  @type widths :: %{ip: non_neg_integer(), item: non_neg_integer(), port: non_neg_integer()}
  @type target :: :console | :file

  @mac_width %{console: 6, file: 17}
  # "~8.2f ms"
  @detail_width 11

  @doc """
  The column widths for these hosts.
  """
  @spec widths([Host.t()]) :: widths()
  def widths(hosts) do
    items = Enum.flat_map(hosts, & &1.items)

    %{
      ip: max_length(hosts, &ip/1),
      item: max_length(items, & &1.name),
      port: max_length(items, &port_label/1)
    }
  end

  defp max_length(values, label) do
    values |> Enum.map(&String.length(label.(&1))) |> Enum.max(fn -> 0 end)
  end

  @doc """
  Formats one result, without a newline.
  """
  @spec format(String.t(), Host.t(), Item.t(), {:ok, number()} | {:error, term()}, widths(), target()) ::
          iodata()
  def format(timestamp, %Host{} = host, %Item{} = item, result, widths, target) do
    [
      timestamp,
      " ",
      String.pad_trailing(ip(host), widths.ip),
      " ",
      String.pad_trailing(mac_label(host, target), @mac_width[target]),
      " ",
      String.pad_trailing(item.name, widths.item),
      " ",
      String.pad_trailing(port_label(item), widths.port),
      " ",
      status_tag(result, target),
      " ",
      detail(result),
      "  ",
      host.name
    ]
  end

  defp ip(%Host{resolved: nil, address: address}), do: address
  defp ip(%Host{resolved: resolved}), do: resolved

  @doc """
  The MAC column's value.
  """
  @spec mac_label(Host.t(), target()) :: String.t()
  def mac_label(%Host{mac_address: nil, on_link: true}, _target), do: "no-mac"
  def mac_label(%Host{mac_address: nil}, _target), do: "-"
  def mac_label(%Host{}, :console), do: "mac"
  def mac_label(%Host{mac_address: mac}, :file), do: mac

  defp port_label(%Item{type: :icmp}), do: "icmp"
  defp port_label(%Item{type: type, port: port}), do: "#{port}/#{type}"

  defp status_tag({:ok, _rtt_ms}, :console), do: IO.ANSI.green() <> "ok" <> IO.ANSI.reset()
  defp status_tag({:error, _reason}, :console), do: IO.ANSI.red() <> "NG" <> IO.ANSI.reset()
  defp status_tag({:ok, _rtt_ms}, :file), do: "ok"
  defp status_tag({:error, _reason}, :file), do: "NG"

  defp detail({:ok, rtt_ms}), do: :io_lib.format("~8.2f ms", [rtt_ms])

  defp detail({:error, reason}) when is_binary(reason),
    do: String.pad_trailing(reason, @detail_width)

  defp detail({:error, reason}), do: detail({:error, inspect(reason)})
end
