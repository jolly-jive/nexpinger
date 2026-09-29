defmodule ExPingNext.ConsoleSubscriberTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias ExPingNext.{ConsoleSubscriber, Host, Item}

  test "beeps when an item result is an error" do
    host = %Host{name: "gateway", address: "192.0.2.1", items: []}
    item = %Item{name: "ping", type: :icmp}

    output =
      capture_io(fn ->
        ConsoleSubscriber.handle_info({:item_result, host, item, {:error, "timeout"}}, %{})
      end)

    assert output =~ "\a"
    assert output =~ "timeout"
  end

  test "does not beep when an item result succeeds" do
    host = %Host{name: "gateway", address: "192.0.2.1", items: []}
    item = %Item{name: "ping", type: :icmp}

    output =
      capture_io(fn ->
        ConsoleSubscriber.handle_info({:item_result, host, item, {:ok, 1.23}}, %{})
      end)

    refute output =~ "\a"
    assert output =~ "1.23 ms"
  end
end
