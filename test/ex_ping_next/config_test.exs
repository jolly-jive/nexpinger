defmodule ExPingNext.ConfigTest do
  use ExUnit.Case, async: true

  alias ExPingNext.{Config, Item}

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
    assert message =~ "には port の指定が必要です"
  end

  defp write_config!(content) do
    path = Path.join(System.tmp_dir!(), "exping-config-#{System.unique_integer([:positive])}.yml")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
