defmodule NexPinger.MacResolverTest do
  use ExUnit.Case, async: true

  alias NexPinger.MacResolver

  describe "parse_ip_neigh/1" do
    test "takes the lladdr of IPv4 and IPv6 entries, STALE included" do
      assert MacResolver.parse_ip_neigh("192.168.0.1 dev eth0 lladdr 00:00:5E:00:53:01 REACHABLE\n") ==
               "00:00:5e:00:53:01"

      assert MacResolver.parse_ip_neigh("2001:db8::1 dev eth0 lladdr 00:00:5e:00:53:02 router STALE\n") ==
               "00:00:5e:00:53:02"
    end

    test "nil for entries without lladdr or no entry" do
      assert MacResolver.parse_ip_neigh("192.168.0.9 dev eth0 FAILED\n") == nil
      assert MacResolver.parse_ip_neigh("192.168.0.9 dev eth0 INCOMPLETE\n") == nil
      assert MacResolver.parse_ip_neigh("") == nil
    end
  end

  test "parse_arp/1 reads Windows arp -a output" do
    output = """

    Interface: 192.168.0.130 --- 0x5
      Internet Address      Physical Address      Type
      192.168.0.1           00-00-5e-00-53-01     dynamic
    """

    assert MacResolver.parse_arp(output) == "00:00:5e:00:53:01"
    assert MacResolver.parse_arp("No ARP Entries Found.\n") == nil
  end

  describe "cached/3" do
    test "reuses a result, nil included, for 15 s" do
      # Unique key: the cache table is shared
      ip = "cache-test-#{System.unique_integer([:positive])}"
      parent = self()

      fetch = fn ip ->
        send(parent, {:fetched, ip})
        nil
      end

      assert MacResolver.cached(ip, 0, fetch) == nil
      assert_received {:fetched, ^ip}

      assert MacResolver.cached(ip, 14_999, fetch) == nil
      refute_received {:fetched, _}

      assert MacResolver.cached(ip, 15_000, fn _ip -> "00:00:5e:00:53:01" end) ==
               "00:00:5e:00:53:01"

      assert MacResolver.cached(ip, 15_001, fetch) == "00:00:5e:00:53:01"
      refute_received {:fetched, _}
    end
  end
end
