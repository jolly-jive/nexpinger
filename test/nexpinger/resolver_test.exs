defmodule NexPinger.ResolverTest do
  use ExUnit.Case, async: true

  alias NexPinger.Resolver

  @v6_loopback {0, 0, 0, 0, 0, 0, 0, 1}

  describe "resolve/2" do
    test "returns an IP literal as is" do
      assert Resolver.resolve("192.0.2.1", :auto) == {:ok, [{192, 0, 2, 1}]}
      assert Resolver.resolve("192.0.2.1", :ipv4) == {:ok, [{192, 0, 2, 1}]}
      assert Resolver.resolve("::1", :auto) == {:ok, [@v6_loopback]}
      assert Resolver.resolve("::1", :ipv6) == {:ok, [@v6_loopback]}
    end

    test "rejects an IP literal of the other family" do
      assert Resolver.resolve("192.0.2.1", :ipv6) == {:error, "not an IPv6 address"}
      assert Resolver.resolve("::1", :ipv4) == {:error, "not an IPv4 address"}
    end

    test "resolves a name to the family's records" do
      assert {:ok, [{127, _, _, _} | _]} = Resolver.resolve("localhost", :ipv4)
      assert {:ok, [{127, _, _, _} | _]} = Resolver.resolve("localhost", :auto)
    end

    test "an unknown host" do
      for family <- [:ipv4, :ipv6, :auto] do
        assert Resolver.resolve("no-such-host.invalid", family) == {:error, "unknown host"}
      end
    end
  end

  test "literal_family/1" do
    assert Resolver.literal_family("192.0.2.1") == :ipv4
    assert Resolver.literal_family("2001:db8::1") == :ipv6
    assert Resolver.literal_family("example.com") == nil
  end

  test "socket_family/1" do
    assert Resolver.socket_family({192, 0, 2, 1}) == :inet
    assert Resolver.socket_family(@v6_loopback) == :inet6
  end

  test "to_string/1" do
    assert Resolver.to_string({192, 0, 2, 1}) == "192.0.2.1"
    assert Resolver.to_string({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}) == "2001:db8::1"
  end
end
