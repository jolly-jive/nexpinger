defmodule NexPinger.CLI do
  @moduledoc """
  escript entry point.
  Usage: nexpinger [--log-file PATH [--log-format FORMAT]] [--no-stdout] [--help] [config file...]
  """

  alias NexPinger.{
    Config,
    ConsoleSubscriber,
    FileSubscriber,
    Prober,
    Resolver,
    Runner,
    TerminalInput,
    UdpProbe
  }

  @usage """
  Usage: nexpinger [options] <config file>...

    --log-file PATH     write monitoring results to a log file
    --log-format FORMAT log file format: text, tsv or jsonl (default: text)
    --no-stdout         disable console output
    --stats-window N    use the last N attempts for RTT statistics (default: 1000)
    --stats-width N     use an 80- or 120-column statistics layout
    --ping-command      always use the OS ping command for ICMP
    --help              show this help message

  """

  @spec parse_options([String.t()]) :: {keyword(), [String.t()], [String.t()]}
  def parse_options(argv) do
    OptionParser.parse(argv,
      strict: [
        log_file: :string,
        log_format: :string,
        no_stdout: :boolean,
        stats_window: :integer,
        stats_width: :integer,
        ping_command: :boolean,
        help: :boolean
      ]
    )
  end

  def main(argv) do
    {opts, args, invalid} = parse_options(argv)

    if invalid != [] do
      invalid_options = Enum.map_join(invalid, ", ", fn {option, _value} -> option end)
      IO.puts(:stderr, "Invalid option: #{invalid_options}")
      IO.puts(:stderr, @usage)
      System.halt(1)
    end

    validate_stats_options!(opts)

    log_format =
      case log_format(opts) do
        {:ok, format} ->
          format

        {:error, message} ->
          IO.puts(:stderr, message)
          System.halt(1)
      end

    if Keyword.get(opts, :help, false) do
      IO.puts(@usage)
      System.halt(0)
    end

    log_file = Keyword.get(opts, :log_file)
    stdout_enabled = not Keyword.get(opts, :no_stdout, false)
    stats_window = Keyword.get(opts, :stats_window, 1000)
    requested_stats_width = Keyword.get(opts, :stats_width)

    if Keyword.get(opts, :ping_command, false) do
      Prober.force_ping_command()
    end

    case args do
      [] ->
        IO.puts(:stderr, "No config file given")
        System.halt(1)

      paths ->
        run(paths, log_file, log_format, stdout_enabled, stats_window, requested_stats_width)
    end
  end

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

  defp run(paths, log_file, log_format, stdout_enabled, stats_window, requested_stats_width) do
    case load_hosts(paths) do
      {:ok, []} ->
        IO.puts(:stderr, "No hosts in config: #{Enum.join(paths, ", ")}")
        System.halt(1)

      {:ok, hosts} ->
        case resolve_errors(hosts) do
          [] ->
            :ok

          errors ->
            Enum.each(errors, &IO.puts(:stderr, &1))
            System.halt(1)
        end

        item_count = Enum.sum(Enum.map(hosts, &length(&1.items)))
        stats_width = requested_stats_width || TerminalInput.terminal_width()
        stats_height = TerminalInput.terminal_height()
        interactive? = stdout_enabled and TerminalInput.available?()

        ConsoleSubscriber.configure(hosts, stats_window, stats_width, stats_height)

        IO.puts(
          "NexPinger (Elixir CUI) started: #{length(hosts)} hosts, #{item_count} items (#{Enum.join(paths, ", ")})"
        )

        if log_file do
          IO.puts("Log file: #{log_file} (#{log_format})")
        end

        IO.puts("stdout: #{if stdout_enabled, do: "enabled", else: "disabled"}")

        if Enum.any?(hosts, fn host -> Enum.any?(host.items, &(&1.type == :icmp)) end) do
          IO.puts("ICMP: #{Prober.icmp_method()}")
        end

        Enum.each(ntp_warnings(hosts), &IO.puts(:stderr, &1))

        IO.puts(String.duplicate("-", 60))

        if log_file do
          start_log_file_subscriber(log_file, log_format)
        end

        if stdout_enabled do
          NexPinger.Broadcaster.subscribe(NexPinger.ConsoleSubscriber)
        end

        Enum.each(hosts, fn host ->
          Enum.each(host.items, fn item ->
            case DynamicSupervisor.start_child(
                   NexPinger.MonitorSupervisor,
                   {Runner, {host, item}}
                 ) do
              {:ok, _pid} -> :ok
              {:error, reason} -> IO.puts(:stderr, "Failed to start monitor: #{inspect(reason)}")
            end
          end)
        end)

        if interactive? do
          case TerminalInput.run() do
            :quit -> System.halt(0)
            :unavailable -> Process.sleep(:infinity)
          end
        else
          # No key input: keep the main process alive (Ctrl+C to quit)
          Process.sleep(:infinity)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Failed to load config: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc """
  Resolves every host once at startup. Returns a message per host that fails.
  Later failures only make that probe NG.
  """
  @spec resolve_errors([NexPinger.Host.t()]) :: [String.t()]
  def resolve_errors(hosts) do
    for host <- hosts,
        {:error, reason} <- [Resolver.resolve(host.address, host.family)] do
      "Cannot resolve #{host.name}: #{host.address} (family: #{host.family}): #{reason}"
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

  defp validate_stats_options!(opts) do
    stats_window = Keyword.get(opts, :stats_window, 1000)
    stats_width = Keyword.get(opts, :stats_width)

    cond do
      stats_window <= 0 ->
        IO.puts(:stderr, "--stats-window must be >= 1")
        System.halt(1)

      not is_nil(stats_width) and stats_width not in [80, 120] ->
        IO.puts(:stderr, "--stats-width must be 80 or 120")
        System.halt(1)

      true ->
        :ok
    end
  end

  defp load_hosts(paths) do
    result =
      Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, hosts} ->
        case Config.load(path) do
          {:ok, file_hosts} ->
            {:cont, {:ok, [file_hosts | hosts]}}

          {:error, reason} ->
            {:halt, {:error, {path, reason}}}
        end
      end)

    case result do
      {:ok, host_lists} -> {:ok, List.flatten(host_lists)}
      error -> error
    end
  end

  defp start_log_file_subscriber(log_file, log_format) do
    case Process.whereis(:log_file_subscriber) do
      nil ->
        FileSubscriber.start_link(log_file, :log_file_subscriber, nil, log_format)
        NexPinger.Broadcaster.subscribe(:log_file_subscriber)

      _pid ->
        :ok
    end
  end
end
