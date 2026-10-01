defmodule NexPinger.CLITest do
  use ExUnit.Case, async: true

  test "parses a log file option" do
    assert {[
              log_file: "/tmp/monitor.log"
            ], ["config/hosts.yml"], []} =
             NexPinger.CLI.parse_options(["--log-file", "/tmp/monitor.log", "config/hosts.yml"])
  end

  test "does not configure file output without a log file option" do
    assert {[], ["config/hosts.yml"], []} =
             NexPinger.CLI.parse_options(["config/hosts.yml"])
  end

  test "parses no-stdout and help flags" do
    assert {[
              no_stdout: true,
              help: true
            ], [], []} =
             NexPinger.CLI.parse_options(["--no-stdout", "--help"])
  end

  test "parses RTT statistics window and width options" do
    assert {[
              stats_window: 250,
              stats_width: 120
            ], ["config/hosts.yml"], []} =
             NexPinger.CLI.parse_options([
               "--stats-window",
               "250",
               "--stats-width",
               "120",
               "config/hosts.yml"
             ])
  end

  test "parses the ping-command flag" do
    assert {[ping_command: true], ["config/hosts.yml"], []} =
             NexPinger.CLI.parse_options(["--ping-command", "config/hosts.yml"])
  end

  test "parses the log format option" do
    assert {[log_file: "monitor.tsv", log_format: "tsv"], ["config/hosts.yml"], []} =
             NexPinger.CLI.parse_options([
               "--log-file",
               "monitor.tsv",
               "--log-format",
               "tsv",
               "config/hosts.yml"
             ])
  end

  test "defaults the log format to text" do
    assert {:ok, :text} = NexPinger.CLI.log_format([])
    assert {:ok, :text} = NexPinger.CLI.log_format(log_file: "monitor.log")
  end

  test "accepts text, tsv and jsonl log formats" do
    for format <- [:text, :tsv, :jsonl] do
      assert {:ok, ^format} =
               NexPinger.CLI.log_format(log_file: "monitor.log", log_format: "#{format}")
    end
  end

  test "rejects an unknown log format" do
    assert {:error, message} =
             NexPinger.CLI.log_format(log_file: "monitor.log", log_format: "csv")

    assert message =~ "text, tsv, jsonl"
  end

  test "rejects a log format without a log file" do
    assert {:error, message} = NexPinger.CLI.log_format(log_format: "tsv")
    assert message =~ "--log-file"
  end

  test "warns about NTP items polled faster than 8000 ms" do
    items = [
      %NexPinger.Item{name: "fast", type: :udp, service: :ntp, port: 123, interval: 1000},
      %NexPinger.Item{name: "slow", type: :udp, service: :ntp, port: 123, interval: 8000},
      %NexPinger.Item{name: "dns", type: :udp, service: :dns, port: 53, interval: 1000}
    ]

    host = %NexPinger.Host{name: "server", address: "192.0.2.1", items: items}

    assert [warning] = NexPinger.CLI.ntp_warnings([host])
    assert warning =~ "server/fast"
  end

  test "returns invalid options" do
    assert {[], ["config/hosts.yml"], [{"--unknown", nil}]} =
             NexPinger.CLI.parse_options(["--unknown", "config/hosts.yml"])
  end
end
