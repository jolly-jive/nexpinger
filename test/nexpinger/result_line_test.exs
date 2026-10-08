defmodule NexPinger.ResultLineTest do
  use ExUnit.Case, async: true

  alias NexPinger.{Host, Item, ResultLine}

  describe "widths/1" do
    test "takes the longest value of each column" do
      ping = %Item{name: "ping", type: :icmp}
      https = %Item{name: "https", type: :tcp, port: 443}
      dns = %Item{name: "dns", type: :udp, port: 53}

      web = %Host{name: "web", address: "203.0.113.10", items: [ping, https]}
      gateway = %Host{name: "gateway", address: "192.0.2.1", items: [dns]}

      assert ResultLine.widths([web, gateway]) == %{ip: 12, item: 5, port: 7}
    end

    test "uses the resolved address instead of the configured one" do
      ping = %Item{name: "ping", type: :icmp}

      host = %Host{
        name: "web",
        address: "www.example.com",
        resolved: "203.0.113.10",
        items: [ping]
      }

      assert ResultLine.widths([host]).ip == 12
    end

    test "is zero for the item columns when a host has no items" do
      host = %Host{name: "gateway", address: "192.0.2.1", items: []}

      assert ResultLine.widths([host]) == %{ip: 9, item: 0, port: 0}
    end

    test "is all zero without hosts" do
      assert ResultLine.widths([]) == %{ip: 0, item: 0, port: 0}
    end
  end
end
