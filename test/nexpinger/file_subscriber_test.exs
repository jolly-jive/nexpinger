defmodule NexPinger.FileSubscriberTest do
  use ExUnit.Case, async: true

  alias NexPinger.{FileSubscriber, Host, Item}

  @timestamp "2026-09-30 12:00:00.123"
  @widths %{ip: 0, item: 0, port: 0}

  defp tcp_host,
    do: %Host{
      name: "web",
      address: "192.0.2.10",
      resolved: "192.0.2.10",
      mac_address: "00:00:5e:00:53:01",
      items: []
    }

  defp tcp_item, do: %Item{name: "https", type: :tcp, port: 443}
  defp icmp_host, do: %Host{name: "gateway", address: "192.0.2.1", items: []}
  defp icmp_item, do: %Item{name: "ping", type: :icmp}

  defp record(format, host, item, result) do
    format
    |> FileSubscriber.format_record(@timestamp, host, item, result)
    |> IO.iodata_to_binary()
  end

  describe "text format" do
    test "uses the console layout, with the MAC address" do
      assert record(:text, tcp_host(), tcp_item(), {:ok, 45.671}) ==
               "2026-09-30 12:00:00.123 192.0.2.10 00:00:5e:00:53:01 https 443/tcp ok    45.67 ms  web\n"

      assert record(:text, icmp_host(), icmp_item(), {:error, "timeout"}) ==
               "2026-09-30 12:00:00.123 192.0.2.1 -                 ping icmp NG timeout      gateway\n"
    end

    test "pads the columns to the given widths" do
      widths = %{ip: 12, item: 5, port: 7}

      line =
        :text
        |> FileSubscriber.format_record(@timestamp, icmp_host(), icmp_item(), {:ok, 1.0}, widths)
        |> IO.iodata_to_binary()

      assert line ==
               "2026-09-30 12:00:00.123 192.0.2.1    -                 ping  icmp    ok     1.00 ms  gateway\n"
    end
  end

  describe "tsv format" do
    test "writes raw values separated by tabs" do
      assert record(:tsv, tcp_host(), tcp_item(), {:ok, 45.671}) ==
               "2026-09-30 12:00:00.123\tweb\t192.0.2.10\t192.0.2.10\t00:00:5e:00:53:01\thttps\ttcp\t443\tok\t45.671\t\n"
    end

    test "leaves missing values empty" do
      assert record(:tsv, icmp_host(), icmp_item(), {:error, "timeout"}) ==
               "2026-09-30 12:00:00.123\tgateway\t192.0.2.1\t\t\tping\ticmp\t\tng\t\ttimeout\n"
    end

    test "replaces tabs and newlines inside values with spaces" do
      host = %Host{name: "a\tb", address: "192.0.2.1", items: []}

      line = record(:tsv, host, icmp_item(), {:error, "line1\r\nline2"})

      assert line |> String.trim_trailing("\n") |> String.split("\t") |> length() == 11
      assert line =~ "\ta b\t"
      assert line =~ "\tline1  line2\n"
    end
  end

  describe "jsonl format" do
    test "writes one JSON object per line in field order" do
      line = record(:jsonl, tcp_host(), tcp_item(), {:ok, 45.671})

      assert String.ends_with?(line, "}\n")
      refute line |> String.trim_trailing("\n") |> String.contains?("\n")
      assert String.starts_with?(line, ~s({"timestamp":"2026-09-30 12:00:00.123","host":"web"))

      assert JSON.decode!(line) == %{
               "timestamp" => @timestamp,
               "host" => "web",
               "address" => "192.0.2.10",
               "resolved" => "192.0.2.10",
               "mac" => "00:00:5e:00:53:01",
               "item" => "https",
               "type" => "tcp",
               "port" => 443,
               "status" => "ok",
               "rtt_ms" => 45.671,
               "error" => nil
             }
    end

    test "uses null for missing values" do
      decoded = JSON.decode!(record(:jsonl, icmp_host(), icmp_item(), {:error, "time\"out\n"}))

      assert %{"mac" => nil, "port" => nil, "rtt_ms" => nil, "status" => "ng"} = decoded
      assert decoded["error"] == "time\"out\n"
    end
  end

  describe "file output" do
    @describetag :tmp_dir

    test "writes a TSV header only to an empty file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "monitor.tsv")

      {:ok, state} = FileSubscriber.init({path, :tsv, nil, @widths})
      FileSubscriber.handle_info({:item_result, icmp_host(), icmp_item(), {:ok, 1.5}}, state)
      {:ok, _state} = FileSubscriber.init({path, :tsv, nil, @widths})

      [header | rows] = path |> File.read!() |> String.split("\n", trim: true)

      assert header ==
               "timestamp\thost\taddress\tresolved\tmac\titem\ttype\tport\tstatus\trtt_ms\terror"

      assert [row] = rows
      assert row =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\tgateway\t/
    end

    test "does not write a header for text or jsonl", %{tmp_dir: tmp_dir} do
      for format <- [:text, :jsonl] do
        path = Path.join(tmp_dir, "monitor.#{format}")
        {:ok, _state} = FileSubscriber.init({path, format, nil, @widths})
        assert File.read!(path) == ""
      end
    end
  end
end
