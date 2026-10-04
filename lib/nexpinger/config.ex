defmodule NexPinger.Config do
  @moduledoc """
  Loads a YAML or hosts-format config file into a list of NexPinger.Host.
  """

  alias NexPinger.{Host, Item, Resolver, UdpProbe}

  @top_keys ~w(hosts)
  @host_keys ~w(name address family items)
  @item_keys ~w(name type port service interval timeout)

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
         :ok <- check_keys!(doc, @top_keys, "top level"),
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

  # Unknown keys are errors, so a typo is not silently ignored
  defp check_keys!(map, allowed, label) do
    case Map.keys(map) -- allowed do
      [] ->
        :ok

      unknown ->
        raise "Unknown key: #{unknown |> Enum.sort() |> Enum.map_join(", ", &inspect/1)} (#{label})"
    end
  end

  defp to_host!(map) do
    check_keys!(map, @host_keys, "host: #{inspect(map["name"])}")

    items =
      map
      |> Map.fetch!("items")
      |> Enum.map(&to_item!/1)

    name = Map.fetch!(map, "name")
    address = Map.fetch!(map, "address")
    family = family!(map)

    if family != :auto and Resolver.literal_family(address) not in [nil, family] do
      raise "Host #{inspect(name)}: #{address} is not an #{Resolver.family_name(family)} address"
    end

    %Host{name: name, address: address, family: family, items: items}
  end

  defp family!(map) do
    case Map.get(map, "family", "auto") do
      "ipv4" -> :ipv4
      "ipv6" -> :ipv6
      "auto" -> :auto
      other -> raise "Unknown family: #{inspect(other)} (host: #{inspect(map["name"])})"
    end
  end

  defp to_item!(map) do
    check_keys!(map, @item_keys, "item: #{inspect(map["name"])}")

    type =
      case Map.get(map, "type", "icmp") do
        "icmp" -> :icmp
        "tcp" -> :tcp
        "udp" -> :udp
        other -> raise "Unknown type: #{inspect(other)} (item: #{inspect(map["name"])})"
      end

    if type == :tcp and is_nil(map["port"]) do
      raise "Item #{inspect(map["name"])} (type: tcp) needs a port"
    end

    service = if type == :udp, do: udp_service!(map)
    port = map["port"] || (service && UdpProbe.services()[service])

    %Item{
      name: Map.fetch!(map, "name"),
      type: type,
      service: service,
      port: port,
      interval: Map.get(map, "interval", default_interval(service)),
      timeout: Map.get(map, "timeout", 1000)
    }
  end

  # NTP servers rate-limit fast polling, so NTP defaults to a slower interval
  defp default_interval(:ntp), do: UdpProbe.ntp_min_interval()
  defp default_interval(_service), do: 1000

  defp udp_service!(map) do
    names = UdpProbe.services() |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

    case map["service"] do
      nil ->
        raise "Item #{inspect(map["name"])} (type: udp) needs a service (#{Enum.join(names, ", ")})"

      name ->
        if name in names,
          do: String.to_existing_atom(name),
          else: raise("Unknown service: #{inspect(name)} (item: #{inspect(map["name"])})")
    end
  end
end
