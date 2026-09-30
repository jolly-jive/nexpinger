defmodule NexPinger.ConfigTest do
  use ExUnit.Case, async: true

  alias NexPinger.{Config, Item}

  test "loads multiple items for one host" do
    path =
      write_config!("""
      hosts:
        - name: gateway
          address: 192.168.1.1
          items:
            - name: ping
              type: icmp
              interval: 1000
            - name: https
              type: tcp
              port: 443
              interval: 3000
      """)

    assert {:ok, [host]} = Config.load(path)
    assert host.name == "gateway"
    assert host.address == "192.168.1.1"

    assert host.items == [
             %Item{name: "ping", type: :icmp, interval: 1000},
             %Item{name: "https", type: :tcp, port: 443, interval: 3000}
           ]
  end

  test "auto-detects hosts format and creates ICMP items" do
    path =
      write_config!("""
      # local hosts
      127.0.0.1 localhost localhost.localdomain
      ::1 ip6-localhost ip6-loopback # IPv6 loopback
      192.168.1.5 nas
      """)

    assert {:ok, hosts} = Config.load(path)

    assert Enum.map(hosts, &{&1.name, &1.address}) == [
             {"localhost", "127.0.0.1"},
             {"ip6-localhost", "::1"},
             {"nas", "192.168.1.5"}
           ]

    assert Enum.all?(hosts, fn host ->
             host.items == [%Item{name: "icmp", type: :icmp}]
           end)
  end

  test "requires a port for TCP items" do
    path =
      write_config!("""
      hosts:
        - name: gateway
          address: 192.168.1.1
          items:
            - name: https
              type: tcp
      """)

    assert {:error, message} = Config.load(path)
    assert message =~ "needs a port"
  end

  defp write_config!(content) do
    path = Path.join(System.tmp_dir!(), "nexpinger-config-#{System.unique_integer([:positive])}.yml")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
