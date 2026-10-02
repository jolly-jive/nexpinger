defmodule NexPinger.AddressLabelTest do
  use ExUnit.Case, async: true

  alias NexPinger.{AddressLabel, Host}

  defp host(address, opts \\ []) do
    struct!(%Host{name: "h", address: address, items: []}, opts)
  end

  describe "width/1" do
    test "stays 15 for IPv4 literals only" do
      assert AddressLabel.width([host("192.168.1.1"), host("10.0.0.1")]) == 15
      assert AddressLabel.width([]) == 15
    end

    test "fits an IPv6 literal, up to 24" do
      assert AddressLabel.width([host("2001:db8:1:2::10")]) == 16
      assert AddressLabel.width([host("2001:db8:1:2:a1b2:c3ff:fed4:e5f6")]) == 24
    end

    test "leaves room for the resolved IP of a name" do
      assert AddressLabel.width([host("nas", family: :ipv4)]) == 19
      assert AddressLabel.width([host("nas", family: :ipv6)]) == 24
      assert AddressLabel.width([host("nas")]) == 24
    end
  end

  describe "full/1" do
    test "shows a name with its resolved IP" do
      assert AddressLabel.full(host("www.example.com", resolved: "2001:db8::1")) ==
               "www.example.com=2001:db8::1"
    end

    test "shows a literal, or a name not resolved, as is" do
      assert AddressLabel.full(host("192.0.2.1", resolved: "192.0.2.1")) == "192.0.2.1"
      assert AddressLabel.full(host("www.example.com")) == "www.example.com"
    end
  end

  describe "fit/2" do
    test "pads text that fits" do
      assert AddressLabel.fit(host("192.0.2.1"), 15) == "192.0.2.1      "
      assert AddressLabel.fit(host("web", resolved: "192.0.2.1"), 15) == "web=192.0.2.1  "
    end

    test "cuts the name first, keeping the IP" do
      host = host("www.example.com", resolved: "203.0.113.10")
      assert AddressLabel.fit(host, 24) == "www.examp..=203.0.113.10"
    end

    test "drops the name when too little of it would be left" do
      host = host("www.example.com", resolved: "2001:db8:1:2::10")
      assert AddressLabel.fit(host, 20) == "2001:db8:1:2::10    "
    end

    test "cuts the IP from the left, keeping the interface ID" do
      ip = "2001:db8:1:2:a1b2:c3ff:fed4:e5f6"

      assert AddressLabel.fit(host(ip), 24) == "..:2:a1b2:c3ff:fed4:e5f6"
      assert AddressLabel.fit(host("www.example.com", resolved: ip), 24) == "..:2:a1b2:c3ff:fed4:e5f6"
    end
  end
end
