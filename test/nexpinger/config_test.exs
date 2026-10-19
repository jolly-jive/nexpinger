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

  test "rejects ports, intervals and timeouts that are not integers in range" do
    for {fields, expected} <- [
          {"type: tcp, port: 0", "port must be an integer from 1 to 65535: 0"},
          {"type: tcp, port: 65536", "port must be an integer from 1 to 65535: 65536"},
          {"type: tcp, port: https", ~s|port must be an integer from 1 to 65535: "https"|},
          {"type: udp, service: dns, port: -1", "port must be an integer from 1 to 65535: -1"},
          {"interval: 0", "interval must be an integer from 1 to 86400000: 0"},
          {"interval: 1.5", "interval must be an integer from 1 to 86400000: 1.5"},
          {"interval: 86400001", "interval must be an integer from 1 to 86400000: 86400001"},
          {"timeout: 1s", ~s|timeout must be an integer from 1 to 86400000: "1s"|},
          {"timeout: ", "timeout must be an integer from 1 to 86400000: nil"}
        ] do
      path =
        write_config!("""
        hosts:
          - name: server
            address: 192.0.2.1
            items: [{name: check, #{fields}}]
        """)

      assert {:error, message} = Config.load(path)
      assert message == ~s|Item "check" (host: "server"): | <> expected
    end
  end

  test "requires string names and addresses" do
    for {host, expected} <- [
          {"address: 192.0.2.1", "Host: name is missing"},
          {"name: 123, address: 192.0.2.1", "Host: name must be a string: 123 (quote it)"},
          {~s|name: "", address: 192.0.2.1|, "Host: name is empty"},
          {"name: server", ~s|Host "server": address is missing|},
          {"name: server, address: 10", ~s|Host "server": address must be a string: 10 (quote it)|}
        ] do
      path = write_config!("hosts:\n  - {#{host}, items: [{name: ping}]}\n")

      assert {:error, message} = Config.load(path)
      assert message == expected
    end

    path = write_config!("hosts:\n  - {name: server, address: 192.0.2.1, items: [{name: true}]}\n")
    assert Config.load(path) == {:error, ~s|Item (host: "server"): name must be a string: true (quote it)|}
  end

  test "rejects a malformed structure" do
    for {content, expected} <- [
          {"hosts: server\n", ~s|"hosts" must be a list|},
          {"- server\n", ~s|Not a YAML mapping with "hosts"|},
          {"hosts: [server]\n", ~s|A host must be a mapping: "server"|},
          {"hosts: [{name: s, address: 192.0.2.1}]\n", ~s|Host "s" needs a list of one or more items|},
          {"hosts: [{name: s, address: 192.0.2.1, items: []}]\n", "needs a list of one or more items"},
          {"hosts: [{name: s, address: 192.0.2.1, items: [ping]}]\n", ~s|An item must be a mapping: "ping"|},
          {"hosts: [\n", "Invalid YAML: "}
        ] do
      path = write_config!(content)

      assert {:error, message} = Config.load(path)
      assert message =~ expected
    end
  end

  test "an empty YAML file has no hosts" do
    assert Config.load(write_config!("")) == {:ok, []}
    assert Config.load(write_config!("hosts:\n")) == {:ok, []}
  end

  test "rejects a duplicate host name and item name pair" do
    for content <- [
          """
          hosts:
            - {name: server, address: 192.0.2.1, items: [{name: web, type: tcp, port: 80}]}
            - {name: server, address: 2001:db8::1, items: [{name: web, type: tcp, port: 80}]}
          """,
          """
          hosts:
            - name: server
              address: 192.0.2.1
              items: [{name: web, type: tcp, port: 80}, {name: web, type: tcp, port: 443}]
          """
        ] do
      assert Config.load(write_config!(content)) ==
               {:error,
                ~s|Duplicate item: "web" (host: "server"); a host name and Item name pair must be unique|}
    end
  end

  test "allows a host name to repeat with other item names, and item names on other hosts" do
    path =
      write_config!("""
      hosts:
        - {name: server, address: 192.0.2.1, family: ipv4, items: [{name: ping4}]}
        - {name: server, address: 2001:db8::1, family: ipv6, items: [{name: ping6}]}
        - {name: other, address: 192.0.2.2, items: [{name: ping4}]}
      """)

    assert {:ok, hosts} = Config.load(path)

    assert Enum.map(hosts, &{&1.name, hd(&1.items).name}) == [
             {"server", "ping4"},
             {"server", "ping6"},
             {"other", "ping4"}
           ]
  end

  test "hosts format allows a name on one line only" do
    path = write_config!("127.0.0.1 localhost\n# comment\n\n::1 localhost ip6-localhost\n")

    assert Config.load(path) ==
             {:error,
              "Line 4: localhost is already on line 1; " <>
                "in a hosts-format file a name may appear on one line only"}
  end

  test "hosts format errors name the line" do
    assert Config.load(write_config!("192.0.2.1 a\n192.0.2.2\n")) ==
             {:error, "Line 2: no host name after 192.0.2.2"}

    assert Config.load(write_config!("192.0.2.1 a\nserver b\n")) ==
             {:error, "Line 2: not an IP address: server"}
  end

  test "a missing file is a readable error" do
    assert Config.load("/nonexistent/hosts.yml") ==
             {:error, "Cannot read file: no such file or directory"}
  end

  defp write_config!(content) do
    path = Path.join(System.tmp_dir!(), "nexpinger-config-#{System.unique_integer([:positive])}.yml")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
