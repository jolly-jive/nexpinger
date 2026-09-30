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

  test "returns invalid options" do
    assert {[], ["config/hosts.yml"], [{"--unknown", nil}]} =
             NexPinger.CLI.parse_options(["--unknown", "config/hosts.yml"])
  end
end
