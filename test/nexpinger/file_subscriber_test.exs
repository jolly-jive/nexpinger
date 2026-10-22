defmodule NexPinger.FileSubscriberTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

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

  describe "daily rotation" do
    test "puts the date before the last extension, or at the end without one" do
      for {path, expected} <- [
            {"monitor.tsv", "monitor-2026-09-30.tsv"},
            {"monitor", "monitor-2026-09-30"},
            {"logs.d/monitor", "logs.d/monitor-2026-09-30"},
            {"monitor.log.tsv", "monitor.log-2026-09-30.tsv"},
            {".nexpinger", ".nexpinger-2026-09-30"}
          ] do
        assert FileSubscriber.file_path(path, :daily, @timestamp) == expected
      end
    end

    test "keeps the path without rotation" do
      assert FileSubscriber.file_path("monitor.tsv", nil, @timestamp) == "monitor.tsv"
    end

    @tag :tmp_dir
    test "writes to the file of the result's date", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "monitor.tsv")

      {:ok, state} =
        FileSubscriber.init(
          path: path,
          format: :tsv,
          owner: self(),
          widths: @widths,
          rotate: :daily
        )

      # A result taken before midnight goes to that day's file, even when written after it
      result = {:item_result, icmp_host(), icmp_item(), {:ok, 1.5}, "2026-09-30 23:59:59.999"}
      FileSubscriber.handle_info(result, state)

      written = Path.join(tmp_dir, "monitor-2026-09-30.tsv")
      assert_received {:file_written, ^written}
      refute File.exists?(path)
      assert [_header, row] = written |> File.read!() |> String.split("\n", trim: true)
      assert String.starts_with?(row, "2026-09-30 23:59:59.999\t")
    end
  end

  describe "under a supervisor" do
    @describetag :tmp_dir

    test "subscribes to the Broadcaster again after a restart", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "monitor.log")
      supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, pid} =
        DynamicSupervisor.start_child(
          supervisor,
          {FileSubscriber, path: path, owner: self(), widths: @widths, subscribe: true}
        )

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      wait_for_restart(supervisor, pid)
      # Let the Broadcaster handle the restarted subscriber's subscribe
      :sys.get_state(NexPinger.Broadcaster)

      NexPinger.Broadcaster.publish(icmp_host(), icmp_item(), {:ok, 1.5}, @timestamp)
      assert_receive {:file_written, ^path}
    end
  end

  defp wait_for_restart(supervisor, old_pid, tries \\ 100) do
    case DynamicSupervisor.which_children(supervisor) do
      [{_, pid, _, _}] when is_pid(pid) and pid != old_pid ->
        pid

      _not_yet when tries > 0 ->
        Process.sleep(10)
        wait_for_restart(supervisor, old_pid, tries - 1)
    end
  end

  describe "file output" do
    @describetag :tmp_dir

    test "writes a TSV header only to an empty file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "monitor.tsv")

      {:ok, state} = FileSubscriber.init(path: path, format: :tsv, widths: @widths)

      FileSubscriber.handle_info(
        {:item_result, icmp_host(), icmp_item(), {:ok, 1.5}, @timestamp},
        state
      )

      {:ok, _state} = FileSubscriber.init(path: path, format: :tsv, widths: @widths)

      [header | rows] = path |> File.read!() |> String.split("\n", trim: true)

      assert header ==
               "timestamp\thost\taddress\tresolved\tmac\titem\ttype\tport\tstatus\trtt_ms\terror"

      assert [row] = rows
      assert row =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\tgateway\t/
    end

    test "recreates a moved file, with the TSV header", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "logs", "monitor.tsv"])
      {:ok, state} = FileSubscriber.init(path: path, format: :tsv, widths: @widths)
      result = {:item_result, icmp_host(), icmp_item(), {:ok, 1.5}, @timestamp}
      FileSubscriber.handle_info(result, state)

      File.rename!(Path.dirname(path), Path.join(tmp_dir, "old"))
      FileSubscriber.handle_info(result, state)

      for file <- [path, Path.join([tmp_dir, "old", "monitor.tsv"])] do
        assert [header, _row] = file |> File.read!() |> String.split("\n", trim: true)
        assert String.starts_with?(header, "timestamp\t")
      end
    end

    test "does not write a header for text or jsonl", %{tmp_dir: tmp_dir} do
      for format <- [:text, :jsonl] do
        path = Path.join(tmp_dir, "monitor.#{format}")
        {:ok, _state} = FileSubscriber.init(path: path, format: format, widths: @widths)
        assert File.read!(path) == ""
      end
    end

    test "reports a path it cannot create", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "file")
      File.write!(file, "")
      path = Path.join(file, "monitor.log")

      assert {:error, message} = FileSubscriber.prepare(path, :text)
      assert message =~ "Cannot open log file: #{path}: "

      stderr =
        capture_io(:stderr, fn ->
          assert {:ok, %{failed?: true}} = FileSubscriber.init(path: path, widths: @widths)
        end)

      assert stderr =~ "Log file write failed: #{path}: "
    end

    test "keeps going when a write fails, reporting only the failure and the recovery",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "monitor.log")

      {:ok, state} =
        FileSubscriber.init(path: path, format: :text, owner: self(), widths: @widths)

      result = {:item_result, icmp_host(), icmp_item(), {:ok, 1.5}, @timestamp}

      # A directory in place of the file makes every write fail
      File.rm!(path)
      File.mkdir!(path)

      {state, stderr} =
        with_io(:stderr, fn ->
          {:noreply, state} = FileSubscriber.handle_info(result, state)
          {:noreply, state} = FileSubscriber.handle_info(result, state)
          state
        end)

      assert_received {:file_write_failed, ^path, :eisdir}

      assert stderr ==
               "Log file write failed: #{path}: illegal operation on a directory " <>
                 "(results are not saved until writes succeed)\n"

      File.rmdir!(path)

      {_state, stderr} =
        with_io(:stderr, fn ->
          {:noreply, state} = FileSubscriber.handle_info(result, state)
          {:noreply, state} = FileSubscriber.handle_info(result, state)
          state
        end)

      assert stderr == "Log file writes resumed: #{path}\n"
      assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 2
    end
  end
end
