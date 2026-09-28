defmodule ExPingNext.Config do
  @moduledoc """
  YAML または hosts 形式の設定ファイルを読み込み、ExPingNext.Host のリストに変換する。
  """

  alias ExPingNext.{Host, Item}

  @spec load(String.t()) :: {:ok, [Host.t()]} | {:error, term()}
  def load(path) do
    with {:ok, content} <- File.read(path) do
      case detect_format(content) do
        :hosts -> load_hosts(content)
        :yaml -> load_yaml(content)
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp load_yaml(content) do
    with {:ok, doc} <- YamlElixir.read_from_string(content),
         hosts when is_list(hosts) <- Map.get(doc, "hosts", []) do
      {:ok, Enum.map(hosts, &to_host!/1)}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_format, other}}
    end
  end

  defp detect_format(content) do
    first_line =
      content
      |> String.split(~r/\R/)
      |> Enum.map(&strip_comment/1)
      |> Enum.find(&(&1 != ""))

    case first_line do
      nil ->
        :yaml

      line ->
        [first_field | _] = String.split(line)

        case :inet.parse_address(String.to_charlist(first_field)) do
          {:ok, _address} -> :hosts
          {:error, _reason} -> :yaml
        end
    end
  end

  defp load_hosts(content) do
    content
    |> String.split(~r/\R/)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &parse_hosts_line/2)
    |> case do
      {:ok, hosts} -> {:ok, Enum.reverse(hosts)}
      error -> error
    end
  end

  defp parse_hosts_line({line, line_number}, {:ok, hosts}) do
    case strip_comment(line) |> String.split() do
      [] ->
        {:cont, {:ok, hosts}}

      [address, name | _aliases] ->
        case :inet.parse_address(String.to_charlist(address)) do
          {:ok, _parsed_address} ->
            item = %Item{name: "icmp", type: :icmp}
            host = %Host{name: name, address: address, items: [item]}
            {:cont, {:ok, [host | hosts]}}

          {:error, _reason} ->
            {:halt, {:error, {:invalid_hosts_address, line_number, address}}}
        end

      [address] ->
        {:halt, {:error, {:missing_hosts_name, line_number, address}}}
    end
  end

  defp strip_comment(line) do
    line
    |> String.split("#", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp to_host!(map) do
    items =
      map
      |> Map.fetch!("items")
      |> Enum.map(&to_item!/1)

    %Host{
      name: Map.fetch!(map, "name"),
      address: Map.fetch!(map, "address"),
      items: items
    }
  end

  defp to_item!(map) do
    type =
      case Map.get(map, "type", "icmp") do
        "icmp" -> :icmp
        "tcp" -> :tcp
        other -> raise "不明な type です: #{inspect(other)} (item: #{inspect(map["name"])})"
      end

    if type == :tcp and is_nil(map["port"]) do
      raise "type: tcp のアイテム #{inspect(map["name"])} には port の指定が必要です"
    end

    %Item{
      name: Map.fetch!(map, "name"),
      type: type,
      port: map["port"],
      interval: Map.get(map, "interval", 1000),
      timeout: Map.get(map, "timeout", 1000)
    }
  end
end
