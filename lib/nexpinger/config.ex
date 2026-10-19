defmodule NexPinger.Config do
  @moduledoc """
  Loads a YAML or hosts-format config file into a list of NexPinger.Host.
  """

  alias NexPinger.{Host, Item, Resolver, UdpProbe}

  @top_keys ~w(hosts)
  @host_keys ~w(name address family items)
  @item_keys ~w(name type port service interval timeout)

  # One day; also keeps timers well inside Erlang's limit
  @max_ms 86_400_000

  @doc """
  Errors are messages for the user, without the path.
  """
  @spec load(String.t()) :: {:ok, [Host.t()]} | {:error, String.t()}
  def load(path) do
    with {:ok, content} <- read(path),
         {:ok, hosts} <- parse(content),
         :ok <- check_duplicates(hosts) do
      {:ok, hosts}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  {host name, Item name} identifies a monitor and its statistics, so each pair must be unique.
  A host name may repeat with different Item names (e.g. one host per address family).
  """
  @spec check_duplicates([Host.t()]) :: :ok | {:error, String.t()}
  def check_duplicates(hosts) do
    targets = for host <- hosts, item <- host.items, do: {host.name, item.name}

    case targets -- Enum.uniq(targets) do
      [] ->
        :ok

      [{host_name, item_name} | _] ->
        {:error,
         "Duplicate item: #{inspect(item_name)} (host: #{inspect(host_name)}); " <>
           "a host name and Item name pair must be unique"}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read file: #{:file.format_error(reason)}"}
    end
  end

  defp parse(content) do
    case detect_format(content) do
      :hosts -> load_hosts(content)
      :yaml -> load_yaml(content)
    end
  end

  defp load_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, doc} when is_map(doc) ->
        check_keys!(doc, @top_keys, "top level")

        hosts = Map.get(doc, "hosts") || []
        unless is_list(hosts), do: raise("\"hosts\" must be a list")
        {:ok, Enum.map(hosts, &to_host!/1)}

      {:ok, _doc} ->
        {:error, "Not a YAML mapping with \"hosts\" (nor a hosts-format file)"}

      {:error, error} ->
        {:error, "Invalid YAML: #{Exception.message(error)}"}
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
    |> Enum.reduce_while({:ok, [], %{}}, &parse_hosts_line/2)
    |> case do
      {:ok, hosts, _lines} -> {:ok, Enum.reverse(hosts)}
      error -> error
    end
  end

  # Every host gets the Item "icmp", so a repeated name would repeat the monitor
  defp parse_hosts_line({line, line_number}, {:ok, hosts, lines}) do
    case strip_comment(line) |> String.split() do
      [] ->
        {:cont, {:ok, hosts, lines}}

      [address, name | _aliases] ->
        case {:inet.parse_address(String.to_charlist(address)), lines[name]} do
          {{:ok, _parsed_address}, nil} ->
            item = %Item{name: "icmp", type: :icmp}
            host = %Host{name: name, address: address, items: [item]}
            {:cont, {:ok, [host | hosts], Map.put(lines, name, line_number)}}

          {{:ok, _parsed_address}, first_line} ->
            {:halt,
             {:error,
              "Line #{line_number}: #{name} is already on line #{first_line}; " <>
                "in a hosts-format file a name may appear on one line only"}}

          {{:error, _reason}, _first_line} ->
            {:halt, {:error, "Line #{line_number}: not an IP address: #{address}"}}
        end

      [address] ->
        {:halt, {:error, "Line #{line_number}: no host name after #{address}"}}
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
    unless is_map(map), do: raise("A host must be a mapping: #{inspect(map)}")
    label = "host: #{inspect(map["name"])}"
    check_keys!(map, @host_keys, label)

    name = string!(map, "name", "Host")
    address = string!(map, "address", "Host #{inspect(name)}")
    family = family!(map)

    if family != :auto and Resolver.literal_family(address) not in [nil, family] do
      raise "Host #{inspect(name)}: #{address} is not an #{Resolver.family_name(family)} address"
    end

    items =
      case Map.get(map, "items") do
        [_ | _] = items -> Enum.map(items, &to_item!(&1, name))
        _other -> raise "Host #{inspect(name)} needs a list of one or more items"
      end

    %Host{name: name, address: address, family: family, items: items}
  end

  # A YAML scalar like 123 or true is not a string; quoting it makes one
  defp string!(map, key, owner) do
    case Map.get(map, key) do
      nil -> raise "#{owner}: #{key} is missing"
      "" -> raise "#{owner}: #{key} is empty"
      value when is_binary(value) -> value
      value -> raise "#{owner}: #{key} must be a string: #{inspect(value)} (quote it)"
    end
  end

  defp family!(map) do
    case Map.get(map, "family", "auto") do
      "ipv4" -> :ipv4
      "ipv6" -> :ipv6
      "auto" -> :auto
      other -> raise "Unknown family: #{inspect(other)} (host: #{inspect(map["name"])})"
    end
  end

  defp to_item!(map, host_name) do
    unless is_map(map), do: raise("An item must be a mapping: #{inspect(map)}")
    check_keys!(map, @item_keys, "item: #{inspect(map["name"])}")

    name = string!(map, "name", "Item (host: #{inspect(host_name)})")
    owner = "Item #{inspect(name)} (host: #{inspect(host_name)})"

    type =
      case Map.get(map, "type", "icmp") do
        "icmp" -> :icmp
        "tcp" -> :tcp
        "udp" -> :udp
        other -> raise "Unknown type: #{inspect(other)} (item: #{inspect(name)})"
      end

    if type == :tcp and is_nil(map["port"]) do
      raise "#{owner} needs a port (type: tcp)"
    end

    service = if type == :udp, do: udp_service!(map)

    port =
      case map["port"] do
        nil -> service && UdpProbe.services()[service]
        _port -> integer!(map, "port", 1..65535, owner)
      end

    %Item{
      name: name,
      type: type,
      service: service,
      port: port,
      interval: integer!(map, "interval", 1..@max_ms, owner, default_interval(service)),
      timeout: integer!(map, "timeout", 1..@max_ms, owner, 1000)
    }
  end

  defp integer!(map, key, first..last//1, owner, default \\ nil) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value >= first and value <= last ->
        value

      value ->
        raise "#{owner}: #{key} must be an integer from #{first} to #{last}: #{inspect(value)}"
    end
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
