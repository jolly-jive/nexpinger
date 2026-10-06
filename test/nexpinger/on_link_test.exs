defmodule NexPinger.OnLinkTest do
  use ExUnit.Case, async: true

  alias NexPinger.OnLink

  @networks [
    {{192, 168, 1, 10}, {255, 255, 255, 0}},
    {{0x2001, 0xDB8, 0, 1, 0, 0, 0, 0x10}, {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0, 0, 0, 0}},
    {{10, 0, 0, 1}, {255, 255, 255, 255}}
  ]

  describe "on_link?/2" do
    test "is true for an IP in an interface's subnet" do
      assert OnLink.on_link?({192, 168, 1, 1}, @networks)
      assert OnLink.on_link?({0x2001, 0xDB8, 0, 1, 0, 0, 0, 1}, @networks)
    end

    test "is false for an IP outside every subnet" do
      refute OnLink.on_link?({192, 168, 2, 1}, @networks)
      refute OnLink.on_link?({0x2001, 0xDB8, 0, 2, 0, 0, 0, 1}, @networks)
      refute OnLink.on_link?({10, 0, 0, 2}, @networks)
      refute OnLink.on_link?({192, 168, 1, 1}, [])
    end

    test "is false for this host's own addresses" do
      refute OnLink.on_link?({192, 168, 1, 10}, @networks)
      refute OnLink.on_link?({10, 0, 0, 1}, @networks)
    end

    test "is false for an unresolved host" do
      refute OnLink.on_link?(nil, @networks)
    end
  end

  describe "networks/1" do
    test "pairs each address with its netmask" do
      opts = [
        flags: [:up, :broadcast, :running, :multicast],
        addr: {192, 168, 1, 10},
        netmask: {255, 255, 255, 0},
        broadaddr: {192, 168, 1, 255},
        addr: {0xFE80, 0, 0, 0, 0, 0, 0, 1},
        netmask: {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0, 0, 0, 0},
        hwaddr: [0, 0, 0x5E, 0, 0x53, 1]
      ]

      assert OnLink.networks(opts) == [
               {{192, 168, 1, 10}, {255, 255, 255, 0}},
               {{0xFE80, 0, 0, 0, 0, 0, 0, 1}, {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0, 0, 0, 0}}
             ]
    end

    test "skips loopback interfaces" do
      opts = [flags: [:up, :loopback, :running], addr: {127, 0, 0, 1}, netmask: {255, 0, 0, 0}]

      assert OnLink.networks(opts) == []
    end
  end
end
