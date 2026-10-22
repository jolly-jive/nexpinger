defmodule NexPinger.CLI do
  @moduledoc """
  escript entry point.
  Usage: nexpinger [--log-file PATH [--log-format FORMAT] [--log-rotate daily]] [--no-stdout] [--version] [--help] [config file...]
  """

  alias NexPinger.{
    Config,
    ConsoleSubscriber,
    FileSubscriber,
    OnLink,
    Prober,
    Resolver,
    ResultLine,
    Runner,
    TerminalInput,
    Timestamp,
    UdpProbe
  }

  @type log :: %{
          file: String.t(),
          format: FileSubscriber.format(),
          rotate: FileSubscriber.rotate()
        }

  @type settings :: %{
          paths: [String.t()],
          log: log() | nil,
          stdout_enabled: boolean(),
          stats_window: pos_integer(),
          stats_width: 80..120 | nil,
          ping_command: boolean()
        }

  @type plan :: %{
          settings: settings(),
          hosts: [NexPinger.Host.t()],
          address_warnings: [String.t()]
        }

  @usage """
  Usage: nexpinger [options] <config file>...

    --log-file PATH     write monitoring results to a log file
    --log-format FORMAT log file format: text, tsv or jsonl (default: text)
    --log-rotate daily  write a log file per day (monitor.log -> monitor-YYYY-MM-DD.log)
    --no-stdout         disable console output
    --stats-window N    use the last N attempts for RTT statistics (default: 1000)
    --stats-width N     fix the statistics screen width (80-120; default: terminal width)
    --ping-command      always use the OS ping command for ICMP
    --version           show the version
    --help              show this help message

  """

  @version Mix.Project.config()[:version]

  @spec parse_options([String.t()]) ::
          {keyword(), [String.t()], [{String.t(), String.t() | nil}]}
  def parse_options(argv) do
    OptionParser.parse(argv,
      strict: [
        log_file: :string,
        log_format: :string,
        log_rotate: :string,
        no_stdout: :boolean,
        stats_window: :integer,
        stats_width: :integer,
        ping_command: :boolean,
        version: :boolean,
        help: :boolean
      ]
    )
  end

  # Exits here, or on quit once monitoring runs; the steps below return what to do
  def main(argv) do
    result =
      with {:ok, settings} <- parse(argv) do
        prepare(settings)
      end

    case result do
      {:ok, plan} ->
        start(plan)

      {:help, text} ->
        IO.puts(text)
        System.halt(0)

      {:version, text} ->
        IO.puts(text)
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @doc """
  Reads the command line, without side effects.
  `{:help, text}` and `{:version, text}` exit 0 after printing the text; `{:error, message}` exits 1.
  """
  @spec parse([String.t()]) ::
          {:ok, settings()} | {:help, String.t()} | {:version, String.t()} | {:error, String.t()}
  def parse(argv) do
    {opts, paths, invalid} = parse_options(argv)

    with :ok <- check_invalid(invalid),
         :ok <- check_version(opts),
         :ok <- check_stats_options(opts),
         {:ok, log} <- log_settings(opts),
         :ok <- check_help(opts),
         :ok <- check_paths(paths) do
      {:ok,
       %{
         paths: paths,
         log: log,
         stdout_enabled: not Keyword.get(opts, :no_stdout, false),
         stats_window: Keyword.get(opts, :stats_window, 1000),
         stats_width: Keyword.get(opts, :stats_width),
         ping_command: Keyword.get(opts, :ping_command, false)
       }}
    end
  end

  @doc """
  Loads the config files, resolves the hosts and checks that the log file can be opened
  (creating it if needed). Starts nothing.
  """
  @spec prepare(settings(), function()) :: {:ok, plan()} | {:error, String.t()}
  def prepare(settings, resolve \\ &Resolver.resolve/2) do
    with {:ok, hosts} <- load_hosts(settings.paths),
         {:ok, hosts, address_warnings} <- resolve_all(hosts, resolve),
         :ok <- prepare_log_file(settings.log) do
      networks = OnLink.networks()
      hosts = Enum.map(hosts, &%{&1 | on_link: OnLink.on_link?(&1.ip, networks)})
      {:ok, %{settings: settings, hosts: hosts, address_warnings: address_warnings}}
    end
  end

  @spec version_string() :: String.t()
  def version_string, do: "NexPinger #{@version}"

  @doc """
  Validates `--log-format` and returns the log file format. Error if given without `--log-file`.
  """
  @spec log_format(keyword()) :: {:ok, FileSubscriber.format()} | {:error, String.t()}
  def log_format(opts) do
    names = Enum.map(FileSubscriber.formats(), &Atom.to_string/1)

    case {Keyword.get(opts, :log_format), Keyword.get(opts, :log_file)} do
      {nil, _log_file} ->
        {:ok, :text}

      {_format, nil} ->
        {:error, "--log-format requires --log-file"}

      {format, _log_file} ->
        if format in names,
          do: {:ok, String.to_existing_atom(format)},
          else: {:error, "--log-format must be one of: #{Enum.join(names, ", ")}"}
    end
  end

  @doc """
  Validates `--log-rotate` and returns the rotation. Error if given without `--log-file`.
  """
  @spec log_rotate(keyword()) :: {:ok, FileSubscriber.rotate()} | {:error, String.t()}
  def log_rotate(opts) do
    names = Enum.map(FileSubscriber.rotates(), &Atom.to_string/1)

    case {Keyword.get(opts, :log_rotate), Keyword.get(opts, :log_file)} do
      {nil, _log_file} ->
        {:ok, nil}

      {_rotate, nil} ->
        {:error, "--log-rotate requires --log-file"}

      {rotate, _log_file} ->
        if rotate in names,
          do: {:ok, String.to_existing_atom(rotate)},
          else: {:error, "--log-rotate must be one of: #{Enum.join(names, ", ")}"}
    end
  end

  defp start(%{settings: settings, hosts: hosts, address_warnings: address_warnings}) do
    if settings.ping_command do
      Prober.force_ping_command()
    end

    interactive? = settings.stdout_enabled and TerminalInput.available?()

    if settings.log do
      start_log_file_subscriber(settings.log, ResultLine.widths(hosts))
    end

    print_banner(hosts, settings.paths, settings.log, settings.stdout_enabled, address_warnings)

    if settings.stdout_enabled do
      start_console_subscriber(hosts, settings.stats_window, settings.stats_width)
    end

    for host <- hosts, item <- host.items, do: start_monitor(host, item)

    wait_for_quit(interactive?)
  end

  defp print_banner(hosts, paths, log, stdout_enabled, address_warnings) do
    item_count = Enum.sum(Enum.map(hosts, &length(&1.items)))

    IO.puts(
      "NexPinger (Elixir CUI) started: #{length(hosts)} hosts, #{item_count} items (#{Enum.join(paths, ", ")})"
    )

    if log do
      IO.puts("Log file: #{log_file_description(log)}")
    end

    IO.puts("stdout: #{if stdout_enabled, do: "enabled", else: "disabled"}")

    icmp_families =
      for host <- hosts, Enum.any?(host.items, &(&1.type == :icmp)), uniq: true do
        Resolver.ip_family(host.ip)
      end

    if icmp_families != [] do
      IO.puts("ICMP: #{Prober.icmp_method(Enum.sort(icmp_families))}")
    end

    Enum.each(resolved_messages(hosts), &IO.puts/1)

    Enum.each(address_warnings ++ ntp_warnings(hosts), &IO.puts(:stderr, &1))

    IO.puts(String.duplicate("-", 60))
  end

  defp start_monitor(host, item) do
    case DynamicSupervisor.start_child(NexPinger.MonitorSupervisor, {Runner, {host, item}}) do
      {:ok, _pid} -> :ok
      {:error, reason} -> IO.puts(:stderr, "Failed to start monitor: #{inspect(reason)}")
    end
  end

  # Without key input, only Ctrl+C quits.
  # Windows reads Ctrl+C as a key, or the VM would show its BREAK menu.
  defp wait_for_quit(interactive?) do
    result = if interactive?, do: TerminalInput.run(), else: TerminalInput.wait_for_interrupt()

    case result do
      :quit -> System.halt(0)
      :unavailable -> Process.sleep(:infinity)
    end
  end

  @doc """
  Resolves every host once at startup; probes keep that IP until exit.
  A name with several addresses uses the first one and gets a warning.
  Returns a message per host that fails, if any.
  """
  @spec resolve_hosts([NexPinger.Host.t()], function()) ::
          {:ok, [NexPinger.Host.t()], warnings :: [String.t()]} | {:error, [String.t()]}
  def resolve_hosts(hosts, resolve \\ &Resolver.resolve/2) do
    results = Enum.map(hosts, &{&1, resolve.(&1.address, &1.family)})

    errors =
      for {host, {:error, reason}} <- results do
        "Cannot resolve #{host.name}: #{host.address} (family: #{host.family}): #{reason}"
      end

    if errors == [] do
      hosts =
        for {host, {:ok, [ip | _]}} <- results do
          %{host | ip: ip, resolved: Resolver.to_string(ip)}
        end

      warnings =
        for {host, {:ok, [ip | [_ | _] = others]}} <- results do
          "Multiple addresses for #{host.name}: #{host.address}: using #{Resolver.to_string(ip)} " <>
            "(also #{Enum.map_join(others, ", ", &Resolver.to_string/1)})"
        end

      {:ok, hosts, warnings}
    else
      {:error, errors}
    end
  end

  @doc """
  Tells which IP each host name was resolved to. Result lines show the IP only.
  """
  @spec resolved_messages([NexPinger.Host.t()]) :: [String.t()]
  def resolved_messages(hosts) do
    for host <- hosts, Resolver.literal_family(host.address) == nil do
      "Resolved: #{host.name}: #{host.address} -> #{host.resolved}"
    end
  end

  @doc """
  Warns about NTP items polled faster than NTP servers usually allow.
  """
  @spec ntp_warnings([NexPinger.Host.t()]) :: [String.t()]
  def ntp_warnings(hosts) do
    min_interval = UdpProbe.ntp_min_interval()

    for host <- hosts,
        item <- host.items,
        item.type == :udp and item.service == :ntp and item.interval < min_interval do
      "Warning: #{host.name}/#{item.name}: NTP interval #{item.interval} ms is under " <>
        "#{min_interval} ms; servers may rate-limit or drop requests"
    end
  end

  defp check_invalid([]), do: :ok

  defp check_invalid(invalid) do
    invalid_options = Enum.map_join(invalid, ", ", fn {option, _value} -> option end)
    {:error, "Invalid option: #{invalid_options}\n#{@usage}"}
  end

  defp check_version(opts) do
    if Keyword.get(opts, :version, false), do: {:version, version_string()}, else: :ok
  end

  defp check_help(opts) do
    if Keyword.get(opts, :help, false), do: {:help, @usage}, else: :ok
  end

  defp check_paths([]), do: {:error, "No config file given"}
  defp check_paths(_paths), do: :ok

  defp check_stats_options(opts) do
    stats_window = Keyword.get(opts, :stats_window, 1000)
    stats_width = Keyword.get(opts, :stats_width)

    cond do
      stats_window <= 0 ->
        {:error, "--stats-window must be >= 1"}

      not is_nil(stats_width) and stats_width not in 80..120 ->
        {:error, "--stats-width must be 80-120"}

      true ->
        :ok
    end
  end

  defp log_settings(opts) do
    with {:ok, format} <- log_format(opts),
         {:ok, rotate} <- log_rotate(opts) do
      log_file = Keyword.get(opts, :log_file)
      {:ok, log_file && %{file: log_file, format: format, rotate: rotate}}
    end
  end

  defp resolve_all(hosts, resolve) do
    case resolve_hosts(hosts, resolve) do
      {:ok, hosts, warnings} -> {:ok, hosts, warnings}
      {:error, errors} -> {:error, Enum.join(errors, "\n")}
    end
  end

  # Checked here for a plain message; once started, failures don't stop monitoring
  defp prepare_log_file(nil), do: :ok

  defp prepare_log_file(%{file: file, format: format, rotate: rotate}),
    do: FileSubscriber.prepare(FileSubscriber.file_path(file, rotate, Timestamp.now()), format)

  defp load_hosts(paths) do
    result =
      Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, hosts} ->
        case Config.load(path) do
          {:ok, file_hosts} ->
            {:cont, {:ok, [file_hosts | hosts]}}

          {:error, message} ->
            {:halt, {:error, "#{path}: #{message}"}}
        end
      end)

    # Each file is checked on load; this catches host/item pairs repeated across files
    with {:ok, host_lists} <- result,
         hosts = host_lists |> Enum.reverse() |> List.flatten(),
         :ok <- Config.check_duplicates(hosts) do
      if hosts == [] do
        {:error, "No hosts in config: #{Enum.join(paths, ", ")}"}
      else
        {:ok, hosts}
      end
    else
      {:error, message} -> {:error, "Failed to load config: #{message}"}
    end
  end

  defp log_file_description(%{file: file, format: format, rotate: nil}), do: "#{file} (#{format})"

  defp log_file_description(%{file: file, format: format, rotate: rotate}),
    do: "#{FileSubscriber.file_path(file, rotate, Timestamp.now())} (#{format}, #{rotate})"

  defp start_console_subscriber(hosts, stats_window, fixed_width) do
    spec =
      {ConsoleSubscriber,
       hosts: hosts, stats_window: stats_window, fixed_width: fixed_width, subscribe: true}

    {:ok, _pid} = DynamicSupervisor.start_child(NexPinger.SubscriberSupervisor, spec)
    :ok
  end

  defp start_log_file_subscriber(%{file: file, format: format, rotate: rotate}, widths) do
    spec =
      {FileSubscriber,
       path: file,
       name: :log_file_subscriber,
       format: format,
       widths: widths,
       rotate: rotate,
       subscribe: true}

    case DynamicSupervisor.start_child(NexPinger.SubscriberSupervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
