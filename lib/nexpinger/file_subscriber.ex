defmodule NexPinger.FileSubscriber do
  @moduledoc """
  Subscriber that writes results from the Broadcaster to a file.

  Formats: `:text` (the screen's layout, with the MAC address), `:tsv` (tab-separated raw data),
  `:jsonl` (one JSON record per line).

  With `:daily` rotation, results go to a file per day: the date goes before the last extension
  (`monitor.tsv` -> `monitor-2026-10-19.tsv`), or at the end without one. The date is the
  result's timestamp's (local time).

  The file is opened for each line, so a log rotation tool can move or delete it: the next line
  creates a new file (with the TSV header). A failed write does not stop monitoring: the result
  is lost, and stderr tells when writes start failing and when they succeed again.

  The CLI starts it under `NexPinger.SubscriberSupervisor` with `subscribe: true`, so a restarted
  subscriber subscribes to the Broadcaster again.
  """

  use GenServer

  alias NexPinger.{Broadcaster, Host, Item, ResultLine, Timestamp}

  @type format :: :text | :tsv | :jsonl
  @type rotate :: nil | :daily

  @formats [:text, :tsv, :jsonl]
  @rotates [:daily]

  @fields ~w(timestamp host address resolved mac item type port status rtt_ms error)

  @spec formats() :: [format()]
  def formats, do: @formats

  @spec rotates() :: [rotate()]
  def rotates, do: @rotates

  @doc """
  Options: `:path` (required), `:name`, `:owner` (gets `{:file_written, path}` and
  `{:file_write_failed, path, reason}`), `:format` (default `:text`), `:widths`, `:rotate`,
  `:subscribe` (subscribe to the Broadcaster on start; default false).
  """
  def start_link(opts) do
    format = Keyword.get(opts, :format, :text)
    rotate = Keyword.get(opts, :rotate)

    unless format in @formats and (rotate == nil or rotate in @rotates) do
      raise ArgumentError, "invalid format or rotate: #{inspect({format, rotate})}"
    end

    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  The file a result with this timestamp goes to.
  """
  @spec file_path(String.t(), rotate(), String.t()) :: String.t()
  def file_path(path, nil, _timestamp), do: path
  def file_path(path, :daily, timestamp), do: dated_path(path, binary_part(timestamp, 0, 10))

  # Path.rootname/1 would drop all of ".nexpinger", which has no extension
  defp dated_path(path, date) do
    extension = Path.extname(path)
    String.replace_suffix(path, extension, "") <> "-" <> date <> extension
  end

  @doc """
  Creates the file (and its directory) and writes the TSV header to an empty file.
  The CLI calls this before starting, to report a bad path as a plain message.
  """
  @spec prepare(String.t(), format()) :: :ok | {:error, String.t()}
  def prepare(path, format) do
    case append_line(path, format, []) do
      :ok -> :ok
      {:error, reason} -> {:error, "Cannot open log file: #{path}: #{:file.format_error(reason)}"}
    end
  end

  @impl true
  def init(opts) do
    state = %{
      path: Keyword.fetch!(opts, :path),
      format: Keyword.get(opts, :format, :text),
      owner: Keyword.get(opts, :owner),
      widths: Keyword.get(opts, :widths, ResultLine.widths([])),
      rotate: Keyword.get(opts, :rotate),
      failed?: false
    }

    if Keyword.get(opts, :subscribe, false) do
      Broadcaster.subscribe(self())
    end

    # Stopping here would fail a restart, and enough of them stop the supervisor.
    # The CLI checks the path with prepare/2 before the first start.
    path = file_path(state.path, state.rotate, Timestamp.now())

    case append_line(path, state.format, []) do
      :ok -> {:ok, state}
      {:error, reason} -> {:ok, report_failure(state, path, reason)}
    end
  end

  @impl true
  def handle_info(
        {:item_result, %Host{} = host, %Item{} = item, result, timestamp},
        %{format: format, owner: owner, widths: widths} = state
      ) do
    path = file_path(state.path, state.rotate, timestamp)
    line = format_record(format, timestamp, host, item, result, widths)

    case append_line(path, format, line) do
      :ok ->
        notify_owner(owner, {:file_written, path})
        {:noreply, report_recovery(state, path)}

      {:error, reason} ->
        notify_owner(owner, {:file_write_failed, path, reason})
        {:noreply, report_failure(state, path, reason)}
    end
  end

  # Report only the changes, not every lost line
  defp report_failure(%{failed?: true} = state, _path, _reason), do: state

  defp report_failure(state, path, reason) do
    IO.puts(
      :stderr,
      "Log file write failed: #{path}: #{:file.format_error(reason)} (results are not saved until writes succeed)"
    )

    %{state | failed?: true}
  end

  defp report_recovery(%{failed?: false} = state, _path), do: state

  defp report_recovery(state, path) do
    IO.puts(:stderr, "Log file writes resumed: #{path}")
    %{state | failed?: false}
  end

  @doc """
  Formats one result as one line (with trailing newline) in the given format.
  """
  @spec format_record(
          format(),
          String.t(),
          Host.t(),
          Item.t(),
          {:ok, number()} | {:error, term()},
          ResultLine.widths()
        ) ::
          iodata()
  def format_record(format, timestamp, host, item, result, widths \\ ResultLine.widths([]))

  def format_record(:text, timestamp, host, item, result, widths) do
    [ResultLine.format(timestamp, host, item, result, widths, :file), "\n"]
  end

  def format_record(:tsv, timestamp, host, item, result, _widths) do
    values =
      Enum.map(record_values(timestamp, host, item, result), fn
        nil -> ""
        value -> value |> value_string() |> String.replace(["\t", "\r", "\n"], " ")
      end)

    [Enum.join(values, "\t"), "\n"]
  end

  def format_record(:jsonl, timestamp, host, item, result, _widths) do
    # Build the object by hand to keep key order; JSON encodes values only
    pairs =
      @fields
      |> Enum.zip(record_values(timestamp, host, item, result))
      |> Enum.map_join(",", fn {key, value} -> JSON.encode!(key) <> ":" <> JSON.encode!(value) end)

    ["{", pairs, "}\n"]
  end

  @doc false
  def tsv_header, do: [Enum.join(@fields, "\t"), "\n"]

  defp record_values(timestamp, %Host{} = host, %Item{} = item, result) do
    {status, rtt_ms, error} =
      case result do
        {:ok, rtt_ms} -> {"ok", rtt_ms, nil}
        {:error, reason} -> {"ng", nil, reason_string(reason)}
      end

    [
      timestamp,
      host.name,
      host.address,
      host.resolved,
      host.mac_address,
      item.name,
      Atom.to_string(item.type),
      item.port,
      status,
      rtt_ms,
      error
    ]
  end

  defp value_string(value) when is_binary(value), do: value
  defp value_string(value) when is_float(value), do: Float.to_string(value)
  defp value_string(value), do: to_string(value)

  defp reason_string(reason) when is_binary(reason), do: reason
  defp reason_string(reason), do: inspect(reason)

  # Recreates a moved or deleted file, with the TSV header
  defp append_line(path, format, line) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, [header(path, format), line], [:append])
    end
  end

  # Don't repeat the header when appending
  defp header(path, :tsv) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > 0 -> []
      _new_or_unreadable -> tsv_header()
    end
  end

  defp header(_path, _format), do: []

  defp notify_owner(nil, _message), do: :ok
  defp notify_owner(owner, message), do: send(owner, message)
end
