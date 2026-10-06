defmodule NexPinger.StatisticsView do
  @moduledoc """
  Builds the fixed-width text of the stats screen.
  """

  alias NexPinger.{ResultLine, Statistics}

  # {column widths, column separator}
  @layouts %{
    80 => {[22, 6, 6, 5, 6, 9, 6, 6, 6], " "},
    120 => {[41, 6, 8, 8, 6, 11, 8, 8, 8], "  "}
  }

  @alignments [:left, :left, :right, :right, :right, :left, :right, :right, :right]
  # Index of the Latest column
  @latest 5

  @spec render(map(), 80 | 120, pos_integer(), non_neg_integer()) :: String.t()
  def render(statistics, width, height, offset) when width in [80, 120] do
    layout = Map.fetch!(@layouts, width)
    entries = Statistics.entries(statistics)
    visible_rows = max(height - 5, 1)
    displayed = entries |> Enum.drop(offset) |> Enum.take(visible_rows)
    finish = min(offset + length(displayed), length(entries))

    lines = [
      fit(
        "NexPinger - Ping Statistics | RTT: ms | Window: #{statistics.window} attempts",
        width
      ),
      format_row(
        ["Target", "MAC", "Runs", "Fail", "Loss%", "Latest", "Avg", "P95", "P99"],
        layout
      )
      |> fit(width),
      String.duplicate("-", width)
    ]

    row_lines = Enum.map(displayed, &format_entry(&1, layout, width))

    footer =
      "Rows #{if entries == [], do: 0, else: offset + 1}-#{finish} of #{length(entries)} | TAB: Ping Results | Up/Down: scroll | Q: quit"

    Enum.join(lines ++ row_lines ++ [fit(footer, width)], "\r\n") <> "\r\n"
  end

  @spec max_offset(non_neg_integer(), 80 | 120, pos_integer()) :: non_neg_integer()
  def max_offset(entry_count, width, height) when width in [80, 120] do
    max(entry_count - max(height - 5, 1), 0)
  end

  defp format_entry(entry, {widths, separator} = layout, width) do
    latency = Statistics.latency(entry)
    attempts = entry.attempts

    latest =
      case entry.latest do
        nil -> "-"
        {:ok, rtt_ms} -> "ok " <> format_number(rtt_ms, Enum.at(widths, @latest) - 3)
        {:error, _reason} -> "NG"
      end

    failure_rate =
      if attempts == 0 do
        "-"
      else
        :erlang.float_to_binary(entry.failures / attempts * 100, decimals: 1) <> "%"
      end

    target = target_label(entry.host.name, entry.item.name, entry.item.port)

    values = [
      target,
      mac_label(entry),
      format_count(attempts, Enum.at(widths, 2)),
      format_count(entry.failures, Enum.at(widths, 3)),
      failure_rate,
      latest,
      format_optional_number(latency.average, Enum.at(widths, 6)),
      format_optional_number(latency.p95, Enum.at(widths, 7)),
      format_optional_number(latency.p99, Enum.at(widths, 8))
    ]

    row = values |> format_row(layout) |> fit(width)

    case entry.latest do
      {:error, _reason} -> paint_ng(row, widths, separator)
      _ -> row
    end
  end

  # The MAC state of the latest attempt
  defp mac_label(%{attempts: 0}), do: "-"
  defp mac_label(%{host: host}), do: ResultLine.mac_label(host, :console)

  # Colors after padding, so ANSI codes do not count toward the width.
  defp paint_ng(row, widths, separator) do
    start = (widths |> Enum.take(@latest) |> Enum.sum()) + @latest * String.length(separator)
    {head, "NG" <> tail} = String.split_at(row, start)
    head <> IO.ANSI.red() <> "NG" <> IO.ANSI.reset() <> tail
  end

  defp target_label(host_name, item_name, nil), do: "#{host_name}/#{item_name}"
  defp target_label(host_name, item_name, port), do: "#{host_name}/#{item_name}:#{port}"

  defp format_row(values, {widths, separator}) do
    values
    |> Enum.zip(widths)
    |> Enum.zip(@alignments)
    |> Enum.map_join(separator, fn {{value, width}, alignment} -> fit(value, width, alignment) end)
  end

  defp format_optional_number(nil, _width), do: "-"
  defp format_optional_number(value, width), do: format_number(value, width)

  defp format_number(value, width) do
    formatted = :erlang.float_to_binary(value / 1, decimals: 2)

    if String.length(formatted) <= width do
      String.pad_leading(formatted, width)
    else
      String.duplicate("#", width)
    end
  end

  defp format_count(value, width) do
    formatted = Integer.to_string(value)

    if String.length(formatted) <= width do
      formatted
    else
      abbreviate_count(value, width)
    end
  end

  defp abbreviate_count(value, width) do
    Enum.find_value(
      [{"k", 1_000}, {"M", 1_000_000}, {"B", 1_000_000_000}],
      String.duplicate("#", width),
      fn {suffix, divisor} ->
        abbreviated = Float.round(value / divisor, 1) |> :erlang.float_to_binary(decimals: 1)
        compact = String.trim_trailing(String.trim_trailing(abbreviated, "0"), ".") <> suffix
        if String.length(compact) <= width, do: compact
      end
    )
  end

  defp fit(value, width, alignment \\ :left) do
    if String.length(value) > width do
      String.slice(value, 0, width - 1) <> "~"
    else
      case alignment do
        :right -> String.pad_leading(value, width)
        :left -> String.pad_trailing(value, width)
      end
    end
  end
end
