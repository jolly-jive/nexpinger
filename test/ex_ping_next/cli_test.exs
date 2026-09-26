defmodule ExPingNext.CLITest do
  use ExUnit.Case, async: true

  test "parses a log file option" do
    assert {[
              log_file: "/tmp/monitor.log"
            ], ["config/hosts.yml"], []} =
             ExPingNext.CLI.parse_options(["--log-file", "/tmp/monitor.log", "config/hosts.yml"])
  end

  test "does not configure file output without a log file option" do
    assert {[], ["config/hosts.yml"], []} =
             ExPingNext.CLI.parse_options(["config/hosts.yml"])
  end

  test "parses no-stdout and help flags" do
    assert {[
              no_stdout: true,
              help: true
            ], [], []} =
             ExPingNext.CLI.parse_options(["--no-stdout", "--help"])
  end

  test "returns invalid options" do
    assert {[], ["config/hosts.yml"], [{"--unknown", nil}]} =
             ExPingNext.CLI.parse_options(["--unknown", "config/hosts.yml"])
  end
end
