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

  test "reports hosts that cannot be resolved at startup" do
    hosts = [
      %NexPinger.Host{name: "ok", address: "127.0.0.1", items: []},
      %NexPinger.Host{name: "ng", address: "no-such-host.invalid", family: :ipv4, items: []}
    ]

    assert {:error, [message]} = NexPinger.CLI.resolve_hosts(hosts)
    assert message =~ "ng: no-such-host.invalid (family: ipv4): unknown host"
  end

  test "sets the IP of each host at startup" do
    hosts = [%NexPinger.Host{name: "ok", address: "127.0.0.1", items: []}]

    assert {:ok, [host], []} = NexPinger.CLI.resolve_hosts(hosts)
    assert host.ip == {127, 0, 0, 1}
    assert host.resolved == "127.0.0.1"
  end

  test "uses the first address of a name with several, and warns" do
    hosts = [
      %NexPinger.Host{name: "web", address: "www.example.com", items: []},
      %NexPinger.Host{name: "db", address: "db.example.com", items: []}
    ]

    resolve = fn
      "www.example.com", :auto -> {:ok, [{203, 0, 113, 10}, {203, 0, 113, 11}, {203, 0, 113, 12}]}
      "db.example.com", :auto -> {:ok, [{192, 0, 2, 1}]}
    end

    assert {:ok, [web, db], [warning]} = NexPinger.CLI.resolve_hosts(hosts, resolve)
    assert web.ip == {203, 0, 113, 10}
    assert web.resolved == "203.0.113.10"
    assert db.resolved == "192.0.2.1"

    assert warning ==
             "Multiple addresses for web: www.example.com: using 203.0.113.10 " <>
               "(also 203.0.113.11, 203.0.113.12)"
  end

  test "tells the resolved IP of host names only" do
    hosts = [
      %NexPinger.Host{
        name: "web",
        address: "www.example.com",
        resolved: "203.0.113.10",
        items: []
      },
      %NexPinger.Host{name: "gateway", address: "192.0.2.1", resolved: "192.0.2.1", items: []}
    ]

    assert NexPinger.CLI.resolved_messages(hosts) ==
             ["Resolved: web: www.example.com -> 203.0.113.10"]
  end

  test "parses the version flag" do
    assert {[version: true], [], []} = NexPinger.CLI.parse_options(["--version"])
  end

  test "reports the mix.exs version" do
    assert NexPinger.CLI.version_string() == "NexPinger #{Mix.Project.config()[:version]}"
  end

  test "returns invalid options" do
    assert {[], ["config/hosts.yml"], [{"--unknown", nil}]} =
             NexPinger.CLI.parse_options(["--unknown", "config/hosts.yml"])
  end

  test "parses the log rotate option" do
    assert {[log_file: "monitor.tsv", log_rotate: "daily"], [], []} =
             NexPinger.CLI.parse_options(["--log-file", "monitor.tsv", "--log-rotate", "daily"])
  end

  test "defaults to no log rotation" do
    assert {:ok, nil} = NexPinger.CLI.log_rotate(log_file: "monitor.log")
  end

  test "accepts daily log rotation" do
    assert {:ok, :daily} = NexPinger.CLI.log_rotate(log_file: "monitor.log", log_rotate: "daily")
  end

  test "rejects an unknown log rotation" do
    assert {:error, message} =
             NexPinger.CLI.log_rotate(log_file: "monitor.log", log_rotate: "hourly")

    assert message =~ "daily"
  end

  test "rejects log rotation without a log file" do
    assert {:error, message} = NexPinger.CLI.log_rotate(log_rotate: "daily")
    assert message =~ "--log-file"
  end

  describe "parse/1" do
    test "returns the settings" do
      assert {:ok, settings} =
               NexPinger.CLI.parse([
                 "--log-file",
                 "monitor.tsv",
                 "--log-format",
                 "tsv",
                 "--no-stdout",
                 "--stats-window",
                 "250",
                 "--stats-width",
                 "100",
                 "--ping-command",
                 "a.yml",
                 "b.yml"
               ])

      assert settings == %{
               paths: ["a.yml", "b.yml"],
               log: %{file: "monitor.tsv", format: :tsv, rotate: nil},
               stdout_enabled: false,
               stats_window: 250,
               stats_width: 100,
               ping_command: true
             }
    end

    test "defaults" do
      assert {:ok, settings} = NexPinger.CLI.parse(["hosts.yml"])

      assert settings == %{
               paths: ["hosts.yml"],
               log: nil,
               stdout_enabled: true,
               stats_window: 1000,
               stats_width: nil,
               ping_command: false
             }
    end

    test "rejects invalid options with the usage" do
      assert {:error, message} = NexPinger.CLI.parse(["--unknown", "--bad", "hosts.yml"])
      assert message =~ ~r/\AInvalid option: --unknown, --bad\nUsage: nexpinger/
    end

    test "shows the version before checking other options" do
      assert {:version, version} = NexPinger.CLI.parse(["--version", "--stats-width", "10"])
      assert version == NexPinger.CLI.version_string()
    end

    test "shows the help without a config file" do
      assert {:help, usage} = NexPinger.CLI.parse(["--help"])
      assert usage =~ "Usage: nexpinger"
    end

    test "checks the options before showing the help" do
      assert {:error, "--stats-width must be 80-120"} =
               NexPinger.CLI.parse(["--help", "--stats-width", "10"])
    end

    test "rejects a stats window under 1" do
      assert {:error, "--stats-window must be >= 1"} =
               NexPinger.CLI.parse(["--stats-window", "0", "hosts.yml"])
    end

    test "rejects a stats width outside 80-120" do
      for width <- ["79", "121"] do
        assert {:error, "--stats-width must be 80-120"} =
                 NexPinger.CLI.parse(["--stats-width", width, "hosts.yml"])
      end
    end

    test "rejects log options without a log file" do
      assert {:error, "--log-format requires --log-file"} =
               NexPinger.CLI.parse(["--log-format", "tsv", "hosts.yml"])

      assert {:error, "--log-rotate requires --log-file"} =
               NexPinger.CLI.parse(["--log-rotate", "daily", "hosts.yml"])
    end

    test "requires a config file" do
      assert {:error, "No config file given"} = NexPinger.CLI.parse(["--no-stdout"])
    end
  end

  describe "prepare/2" do
    @describetag :tmp_dir

    test "returns the resolved hosts and warnings", %{tmp_dir: tmp_dir} do
      path = write!(tmp_dir, "hosts", "127.0.0.1 local\n192.0.2.1 remote\n")
      resolve = fn address, _family -> {:ok, [address |> to_charlist() |> parse_ip()]} end

      assert {:ok, plan} = NexPinger.CLI.prepare(settings([path]), resolve)
      assert Enum.map(plan.hosts, & &1.resolved) == ["127.0.0.1", "192.0.2.1"]
      assert plan.address_warnings == []
      assert plan.settings == settings([path])
    end

    test "reports a config file that cannot be loaded", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing.yml")

      assert NexPinger.CLI.prepare(settings([path])) ==
               {:error,
                "Failed to load config: #{path}: Cannot read file: no such file or directory"}
    end

    test "reports config files without hosts", %{tmp_dir: tmp_dir} do
      path = write!(tmp_dir, "empty", "# no hosts\n")

      assert NexPinger.CLI.prepare(settings([path])) ==
               {:error, "No hosts in config: #{path}"}
    end

    test "reports a target repeated across files", %{tmp_dir: tmp_dir} do
      first = write!(tmp_dir, "first", "127.0.0.1 local\n")
      second = write!(tmp_dir, "second", "127.0.0.2 local\n")

      assert {:error, "Failed to load config: " <> _} =
               NexPinger.CLI.prepare(settings([first, second]))
    end

    test "reports every host that cannot be resolved", %{tmp_dir: tmp_dir} do
      path = write!(tmp_dir, "hosts", "192.0.2.1 a\n192.0.2.2 b\n")
      resolve = fn _address, _family -> {:error, "unknown host"} end

      assert {:error, message} = NexPinger.CLI.prepare(settings([path]), resolve)
      assert [a, b] = String.split(message, "\n")
      assert a =~ "Cannot resolve a: 192.0.2.1"
      assert b =~ "Cannot resolve b: 192.0.2.2"
    end

    test "reports a log file that cannot be opened", %{tmp_dir: tmp_dir} do
      path = write!(tmp_dir, "hosts", "127.0.0.1 local\n")
      # A directory cannot be opened for appending
      log = %{file: tmp_dir, format: :text, rotate: nil}

      assert {:error, "Cannot open log file: " <> _} =
               NexPinger.CLI.prepare(%{settings([path]) | log: log})
    end
  end

  defp settings(paths) do
    %{
      paths: paths,
      log: nil,
      stdout_enabled: true,
      stats_window: 1000,
      stats_width: nil,
      ping_command: false
    }
  end

  defp write!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp parse_ip(address) do
    {:ok, ip} = :inet.parse_address(address)
    ip
  end
end
