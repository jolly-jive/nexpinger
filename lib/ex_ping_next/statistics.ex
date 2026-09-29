defmodule ExPingNext.Statistics do
  @moduledoc """
  Item ごとの累計カウンターと直近試行の RTT 統計。
  """

  alias ExPingNext.{Host, Item}

  @type result :: {:ok, float()} | {:error, term()}

  @spec new([Host.t()], pos_integer()) :: map()
  def new(hosts, window) when is_list(hosts) and is_integer(window) and window > 0 do
    rows =
      for host <- hosts, item <- host.items, into: %{} do
        key = key(host, item)

        {key,
         %{
           host: host,
           item: item,
           attempts: 0,
           failures: 0,
           latest: nil,
           recent: []
         }}
      end

    order = Enum.flat_map(hosts, fn host -> Enum.map(host.items, &key(host, &1)) end)
    %{order: order, rows: rows, window: window}
  end

  @spec record(map(), Host.t(), Item.t(), result()) :: map()
  def record(
        %{rows: rows, order: order, window: window} = statistics,
        %Host{} = host,
        %Item{} = item,
        result
      ) do
    key = key(host, item)
    existing = Map.get(rows, key, new_row(host, item))

    updated = %{
      existing
      | attempts: existing.attempts + 1,
        failures: existing.failures + if(match?({:error, _}, result), do: 1, else: 0),
        latest: result,
        recent: Enum.take([result | existing.recent], window)
    }

    %{
      statistics
      | rows: Map.put(rows, key, updated),
        order: if(key in order, do: order, else: order ++ [key])
    }
  end

  @spec entries(map()) :: [map()]
  def entries(%{order: order, rows: rows}), do: Enum.map(order, &Map.fetch!(rows, &1))

  @spec latency(map()) :: %{
          average: float() | nil,
          p95: float() | nil,
          p99: float() | nil,
          samples: non_neg_integer()
        }
  def latency(%{recent: recent}) do
    samples =
      recent
      |> Enum.flat_map(fn
        {:ok, rtt_ms} -> [rtt_ms]
        {:error, _reason} -> []
      end)

    case samples do
      [] ->
        %{average: nil, p95: nil, p99: nil, samples: 0}

      _ ->
        sorted = Enum.sort(samples)

        %{
          average: Enum.sum(samples) / length(samples),
          p95: percentile(sorted, 0.95),
          p99: percentile(sorted, 0.99),
          samples: length(samples)
        }
    end
  end

  defp key(%Host{name: host_name}, %Item{name: item_name}), do: {host_name, item_name}

  defp new_row(host, item) do
    %{host: host, item: item, attempts: 0, failures: 0, latest: nil, recent: []}
  end

  defp percentile(sorted, proportion) do
    rank = max(ceil(length(sorted) * proportion), 1)
    Enum.at(sorted, rank - 1)
  end
end
