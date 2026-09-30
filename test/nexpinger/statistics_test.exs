defmodule NexPinger.StatisticsTest do
  use ExUnit.Case, async: true

  alias NexPinger.{Host, Item, Statistics}

  test "keeps cumulative counts and calculates latency from successful results in the latest attempts" do
    host = %Host{name: "gateway", address: "192.0.2.1", items: []}
    item = %Item{name: "ping", type: :icmp}
    statistics = Statistics.new([%{host | items: [item]}], 3)

    statistics = Statistics.record(statistics, host, item, {:ok, 1.0})
    statistics = Statistics.record(statistics, host, item, {:ok, 2.0})
    statistics = Statistics.record(statistics, host, item, {:error, "timeout"})
    statistics = Statistics.record(statistics, host, item, {:ok, 3.0})

    [row] = Statistics.entries(statistics)
    assert row.attempts == 4
    assert row.failures == 1
    assert Statistics.latency(row) == %{average: 2.5, p95: 3.0, p99: 3.0, samples: 2}
  end

  test "uses nearest-rank percentiles and returns empty metrics without successful samples" do
    host = %Host{name: "gateway", address: "192.0.2.1", items: []}
    item = %Item{name: "ping", type: :icmp}
    statistics = Statistics.new([%{host | items: [item]}], 100)

    statistics =
      Enum.reduce(1..100, statistics, fn value, acc ->
        Statistics.record(acc, host, item, {:ok, value / 1.0})
      end)

    [row] = Statistics.entries(statistics)
    assert %{p95: 95.0, p99: 99.0, samples: 100} = Statistics.latency(row)

    failed = Statistics.record(statistics, host, item, {:error, "unreachable"})
    [row] = Statistics.entries(failed)

    assert %{average: nil, p95: nil, p99: nil, samples: 0} =
             Statistics.latency(%{row | recent: [{:error, "unreachable"}]})
  end
end
