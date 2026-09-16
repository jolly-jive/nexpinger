defmodule ExPingNext.Config do
  @moduledoc """
  YAML形式の設定ファイルを読み込み、ExPingNext.Host のリストに変換する。
  """

  alias ExPingNext.Host

  @spec load(String.t()) :: {:ok, [Host.t()]} | {:error, term()}
  def load(path) do
    with {:ok, doc} <- YamlElixir.read_from_file(path),
         hosts when is_list(hosts) <- Map.get(doc, "hosts", []) do
      {:ok, Enum.map(hosts, &to_host!/1)}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_format, other}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp to_host!(map) do
    type =
      case Map.get(map, "type", "icmp") do
        "icmp" -> :icmp
        "tcp" -> :tcp
        other -> raise "不明な type です: #{inspect(other)} (host: #{inspect(map["name"])})"
      end

    if type == :tcp and is_nil(map["port"]) do
      raise "type: tcp のホスト #{inspect(map["name"])} には port の指定が必要です"
    end

    %Host{
      name: Map.fetch!(map, "name"),
      address: Map.fetch!(map, "address"),
      type: type,
      port: map["port"],
      interval: Map.get(map, "interval", 1000),
      timeout: Map.get(map, "timeout", 1000)
    }
  end
end
