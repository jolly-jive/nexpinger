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

    for {width, expected_latest, expected_average} <- [
          {80, "ok  1.20", "  1.20"},
          {120, "ok        1.20", "      1.20"}
        ] do
      [row | _] =
        StatisticsView.render(statistics, width, 24, 0)
        |> String.split("\r\n", trim: true)
        |> Enum.drop(3)

      columns = String.split(row, " | ")
      assert Enum.at(columns, 4) == expected_latest
      assert Enum.at(columns, 5) == expected_average
      assert Enum.at(columns, 6) == expected_average
      expected_last = if width == 120, do: expected_average <> "   ", else: expected_average
      assert Enum.at(columns, 7) == expected_last
    end
  end

  test "renders a failed latest result as red NG without changing the row width" do
    host = %Host{name: "web", address: "192.0.2.1", items: []}
    item = %Item{name: "https", type: :tcp, port: 443}
    statistics = Statistics.new([%{host | items: [item]}], 1000)
    statistics = Statistics.record(statistics, host, item, {:error, :timeout})

    for {width, latest_width} <- [{80, 8}, {120, 14}] do
      [row | _] =
        StatisticsView.render(statistics, width, 24, 0)
        |> String.split("\r\n", trim: true)
        |> Enum.drop(3)

      red_ng = IO.ANSI.red() <> "NG" <> IO.ANSI.reset()

      assert Enum.at(String.split(row, " | "), 4) ==
               red_ng <> String.duplicate(" ", latest_width - 2)

      assert String.length(String.replace(row, red_ng, "NG")) == width
    end
  end
end
