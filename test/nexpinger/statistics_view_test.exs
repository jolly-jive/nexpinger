defmodule NexPinger.StatisticsViewTest do
  use ExUnit.Case, async: true

  alias NexPinger.{Host, Item, Statistics, StatisticsView}

  test "renders the configured columns within 80 and 120 characters" do
    host = %Host{name: "web", address: "192.0.2.1", items: []}
    item = %Item{name: "https", type: :tcp, port: 443}
    statistics = Statistics.new([%{host | items: [item]}], 1000)

    for width <- [80, 120] do
      lines = StatisticsView.render(statistics, width, 24, 0) |> String.split("\r\n", trim: true)
      assert Enum.all?(lines, &(String.length(&1) == width))
      assert Enum.at(lines, 0) =~ "RTT: ms"
      assert Enum.at(lines, 3) =~ "web/https:443"
    end
  end

  test "limits displayed rows and clamps the scroll offset" do
    hosts =
      for index <- 1..30 do
        item = %Item{name: "ping", type: :icmp}
        %Host{name: "host-#{index}", address: "192.0.2.1", items: [item]}
      end

    statistics = Statistics.new(hosts, 10)
    lines = StatisticsView.render(statistics, 80, 10, 0) |> String.split("\r\n", trim: true)

    assert length(lines) == 9
    assert StatisticsView.max_offset(30, 80, 10) == 25
  end

  test "renders RTT values with two decimals and right-aligns numeric columns" do
    host = %Host{name: "web", address: "192.0.2.1", items: []}
    item = %Item{name: "https", type: :tcp, port: 443}
    statistics = Statistics.new([%{host | items: [item]}], 1000)
    statistics = Statistics.record(statistics, host, item, {:ok, 1.2})

    for {width, expected} <- [
          {80,
           [
             "Target                 MAC      Runs  Fail  Loss% Latest       Avg    P95    P99",
             "web/https:443          -           1     0   0.0% ok   1.20   1.20   1.20   1.20"
           ]},
          {120,
           [
             "Target                                     MAC         Runs      Fail   Loss%  Latest            Avg       P95       P99",
             "web/https:443                              -              1         0    0.0%  ok     1.20      1.20      1.20      1.20"
           ]}
        ] do
      [header, _rule, row | _] =
        StatisticsView.render(statistics, width, 24, 0)
        |> String.split("\r\n", trim: true)
        |> Enum.drop(1)

      assert [header, row] == expected
    end
  end

  test "shows the MAC state of the latest attempt" do
    item = %Item{name: "ping", type: :icmp}
    host = %Host{name: "gateway", address: "192.0.2.1", on_link: true, items: [item]}
    statistics = Statistics.new([host], 1000)

    mac_column = fn statistics ->
      StatisticsView.render(statistics, 80, 24, 0)
      |> String.split("\r\n", trim: true)
      |> Enum.at(3)
      |> String.slice(23, 6)
    end

    assert mac_column.(statistics) == "-     "

    statistics = Statistics.record(statistics, host, item, {:error, "timeout"})
    assert mac_column.(statistics) == "no-mac"

    with_mac = %{host | mac_address: "00:00:5e:00:53:01"}
    statistics = Statistics.record(statistics, with_mac, item, {:ok, 1.2})
    assert mac_column.(statistics) == "mac   "
  end

  test "shows a latest RTT of 100 ms or more in 80 columns" do
    item = %Item{name: "ping", type: :icmp}
    host = %Host{name: "far", address: "192.0.2.1", items: [item]}
    statistics = Statistics.new([host], 1000) |> Statistics.record(host, item, {:ok, 135.43})

    assert StatisticsView.render(statistics, 80, 24, 0) =~ "ok 135.43 135.43"
  end

  test "renders a failed latest result as red NG without changing the row width" do
    host = %Host{name: "web", address: "192.0.2.1", items: []}
    item = %Item{name: "https", type: :tcp, port: 443}
    statistics = Statistics.new([%{host | items: [item]}], 1000)
    statistics = Statistics.record(statistics, host, item, {:error, :timeout})

    for {width, before_latest} <- [{80, "100.0% "}, {120, "100.0%  "}] do
      [row | _] =
        StatisticsView.render(statistics, width, 24, 0)
        |> String.split("\r\n", trim: true)
        |> Enum.drop(3)

      red_ng = IO.ANSI.red() <> "NG" <> IO.ANSI.reset()

      assert row =~ before_latest <> red_ng <> " "
      assert String.length(String.replace(row, red_ng, "NG")) == width
    end
  end
end
