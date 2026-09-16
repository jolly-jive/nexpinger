defmodule ExPingNext.CLITest do
  use ExUnit.Case, async: true

  test "parses a log file option" do
    assert {[
              log_file: "/tmp/monitor.log"
            ], ["config/hosts.yml"], []} =
             ExPingNext.CLI.parse_options(["--log-file", "/tmp/monitor.log", "config/hosts.yml"])
  end

  test "parses no-stdout and help flags" do
    assert {[
              no_stdout: true,
              help: true
            ], [], []} =
             ExPingNext.CLI.parse_options(["--no-stdout", "--help"])
  end
end
