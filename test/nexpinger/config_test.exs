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

  test "loads UDP items with a service and its default port" do
    path =
      write_config!("""
      hosts:
        - name: server
          address: 192.168.1.1
          items:
            - name: dns
              type: udp
              service: dns
            - name: ntp
              type: udp
              service: ntp
              interval: 10000
            - name: h3
              type: udp
              service: quic
              port: 8443
      """)

    assert {:ok, [host]} = Config.load(path)

    assert host.items == [
             %Item{name: "dns", type: :udp, service: :dns, port: 53},
             %Item{name: "ntp", type: :udp, service: :ntp, port: 123, interval: 10000},
             %Item{name: "h3", type: :udp, service: :quic, port: 8443}
           ]
  end

  test "defaults the NTP interval to 8000 ms" do
    path =
      write_config!("""
      hosts:
        - name: server
          address: 192.168.1.1
          items:
            - name: ntp
              type: udp
              service: ntp
            - name: dns
              type: udp
              service: dns
      """)

    assert {:ok, [host]} = Config.load(path)
    assert Enum.map(host.items, & &1.interval) == [8000, 1000]
  end

  test "requires a known service for UDP items" do
    for {service_line, expected} <- [
          {"", "needs a service"},
          {"service: snmp", "Unknown service"}
        ] do
      path =
        write_config!("""
        hosts:
          - name: server
            address: 192.168.1.1
            items:
              - name: udp
                type: udp
                #{service_line}
        """)

      assert {:error, message} = Config.load(path)
      assert message =~ expected
    end
  end

  test "loads the host family, default auto" do
    path =
      write_config!("""
      hosts:
        - name: default
          address: example.com
          items: [{name: ping}]
        - name: v4
          address: example.com
          family: ipv4
          items: [{name: ping}]
        - name: v6
          address: 2001:db8::1
          family: ipv6
          items: [{name: ping}]
        - name: auto
          address: 192.0.2.1
          family: auto
          items: [{name: ping}]
      """)

    assert {:ok, hosts} = Config.load(path)
    assert Enum.map(hosts, & &1.family) == [:auto, :ipv4, :ipv6, :auto]
  end

  test "hosts format uses family auto" do
    path = write_config!("::1 ip6-localhost\n")

    assert {:ok, [host]} = Config.load(path)
    assert host.family == :auto
  end

  test "rejects an unknown family" do
    path =
      write_config!("""
      hosts:
        - name: server
          address: example.com
          family: inet6
          items: [{name: ping}]
      """)

    assert {:error, message} = Config.load(path)
    assert message =~ "Unknown family"
  end

  test "rejects an IP literal of the other family" do
    for {address, family, expected} <- [
          {"192.0.2.1", "ipv6", "not an IPv6 address"},
          {"2001:db8::1", "ipv4", "not an IPv4 address"}
        ] do
      path =
        write_config!("""
        hosts:
          - name: server
            address: "#{address}"
            family: #{family}
            items: [{name: ping}]
        """)

      assert {:error, message} = Config.load(path)
      assert message =~ expected
    end
  end

  test "rejects unknown keys" do
    for {content, expected} <- [
          {"""
           host:
             - name: server
               address: 192.0.2.1
               items: [{name: ping}]
           """, ~s|Unknown key: "host" (top level)|},
          {"""
           hosts:
             - name: server
               adress: 192.0.2.1
               address: 192.0.2.1
               items: [{name: ping}]
           """, ~s|Unknown key: "adress" (host: "server")|},
          {"""
           hosts:
             - name: server
               address: 192.0.2.1
               items: [{name: ping, intervall: 500, timeot: 100}]
           """, ~s|Unknown key: "intervall", "timeot" (item: "ping")|}
        ] do
      path = write_config!(content)

      assert {:error, message} = Config.load(path)
      assert message =~ expected
    end
  end

  defp write_config!(content) do
    path = Path.join(System.tmp_dir!(), "nexpinger-config-#{System.unique_integer([:positive])}.yml")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
