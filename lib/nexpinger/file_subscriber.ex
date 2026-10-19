defmodule NexPinger.FileSubscriber do
  @moduledoc """
  Subscriber that writes results from the Broadcaster to a file.

  Formats: `:text` (the screen's layout, with the MAC address), `:tsv` (tab-separated raw data),
  `:jsonl` (one JSON record per line).

  A failed write does not stop monitoring: the result is lost, and stderr tells when writes
  start failing and when they succeed again.
  """

  use GenServer

  alias NexPinger.{Host, Item, ResultLine, Timestamp}

  @type format :: :text | :tsv | :jsonl

  @formats [:text, :tsv, :jsonl]

  @fields ~w(timestamp host address resolved mac item type port status rtt_ms error)

  @spec formats() :: [format()]
  def formats, do: @formats

  def start_link(
        path \\ "monitor.log",
        name \\ __MODULE__,
        owner \\ nil,
        format \\ :text,
        widths \\ ResultLine.widths([])
      )
      when format in @formats do
    GenServer.start_link(__MODULE__, {path, format, owner, widths}, name: name)
  end

  @doc """
  Creates the file (and its directory) and writes the TSV header to an empty file.
  The CLI calls this before starting, to report a bad path as a plain message.
  """
  @spec prepare(String.t(), format()) :: :ok | {:error, String.t()}
  def prepare(path, format) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.touch(path),
         {:ok, %File.Stat{size: size}} <- File.stat(path),
         :ok <- write_header(path, format, size) do
      :ok
    else
      {:error, reason} -> {:error, "Cannot open log file: #{path}: #{:file.format_error(reason)}"}
    end
  end

  @impl true
  def init({path, format, owner, widths}) do
    case prepare(path, format) do
      :ok -> {:ok, %{path: path, format: format, owner: owner, widths: widths, failed?: false}}
      {:error, message} -> {:stop, message}
    end
  end

  @impl true
  def handle_info(
        {:item_result, %Host{} = host, %Item{} = item, result},
        %{path: path, format: format, owner: owner, widths: widths} = state
      ) do
    case append_line(path, format_record(format, Timestamp.now(), host, item, result, widths)) do
      :ok ->
        notify_owner(owner, {:file_written, path})
        {:noreply, report_recovery(state)}

      {:error, reason} ->
        notify_owner(owner, {:file_write_failed, path, reason})
        {:noreply, report_failure(state, reason)}
    end
  end

  # Report only the changes, not every lost line
  defp report_failure(%{failed?: true} = state, _reason), do: state

  defp report_failure(%{path: path} = state, reason) do
    IO.puts(
      :stderr,
      "Log file write failed: #{path}: #{:file.format_error(reason)} (results are not saved until writes succeed)"
    )

    %{state | failed?: true}
  end

  defp report_recovery(%{failed?: false} = state), do: state

  defp report_recovery(%{path: path} = state) do
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

  # Don't repeat the header when appending
  defp write_header(path, :tsv, 0), do: append_line(path, tsv_header())
  defp write_header(_path, _format, _size), do: :ok

  defp append_line(path, line), do: File.write(path, line, [:append])

  defp notify_owner(nil, _message), do: :ok
  defp notify_owner(owner, message), do: send(owner, message)
end
