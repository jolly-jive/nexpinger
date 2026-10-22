defmodule NexPinger.StatisticsView do
  @moduledoc """
  Builds the fixed-width text of the stats screen.
  Widths are in terminal columns, so wide (e.g. Japanese) names line up.
  """

  alias NexPinger.{DisplayWidth, ResultLine, Statistics}

  # The 80-column layout. Wider screens (up to 120) widen Target to 41 first,
  # then one number column per column (@number_steps), then the separators from
  # the left to two spaces; 120 columns are 41,6,8,8,6,11,8,8,8 with "  ".
  @min_width 80
  @base_widths [22, 6, 6, 5, 6, 9, 6, 6, 6]
  @target_max_width 41
  # Column indexes: Avg, P95, P99, Latest, Runs, Fail, twice, then Fail again
  @number_steps [6, 7, 8, 5, 2, 3, 6, 7, 8, 5, 2, 3, 3]
  @separator_count 8

  @alignments [:left, :left, :right, :right, :right, :left, :right, :right, :right]
  # Index of the Latest column
  @latest 5

  @doc """
  `dropped` (results the console dropped while it fell behind; not in the statistics) shows
  in the title when not 0.
  """
  @spec render(map(), 80..120, pos_integer(), non_neg_integer(), non_neg_integer()) :: String.t()
  def render(statistics, width, height, offset, dropped \\ 0) when width in 80..120 do
    layout = layout(width)
    entries = Statistics.entries(statistics)
    visible_rows = max(height - 5, 1)
    displayed = entries |> Enum.drop(offset) |> Enum.take(visible_rows)
    finish = min(offset + length(displayed), length(entries))

    lines = [
      fit(
        "NexPinger - Ping Statistics | RTT: ms | Window: #{statistics.window} attempts" <>
          if(dropped > 0, do: " | Dropped: #{dropped}", else: ""),
        width
      ),
      format_row(
        ["Target", "MAC", "Runs", "Fail", "Loss%", "Latest", "Avg", "P95", "P99"],
        layout
      )
      |> fit(width),
      String.duplicate("-", width)
    ]

    row_lines = Enum.map(displayed, &format_entry(&1, layout))

    footer =
      "Rows #{if entries == [], do: 0, else: offset + 1}-#{finish} of #{length(entries)} | TAB: Ping Results | Up/Down: scroll | Q: quit"

    Enum.join(lines ++ row_lines ++ [fit(footer, width)], "\r\n") <> "\r\n"
  end

  @spec max_offset(non_neg_integer(), 80..120, pos_integer()) :: non_neg_integer()
  def max_offset(entry_count, width, height) when width in 80..120 do
    max(entry_count - max(height - 5, 1), 0)
  end

  # {column widths, separators}
  defp layout(width) do
    extra = width - @min_width
    target_extra = min(extra, @target_max_width - hd(@base_widths))
    number_extra = min(extra - target_extra, length(@number_steps))
    separator_extra = extra - target_extra - number_extra

    widths =
      @number_steps
      |> Enum.take(number_extra)
      |> Enum.reduce(List.update_at(@base_widths, 0, &(&1 + target_extra)), fn index, widths ->
        List.update_at(widths, index, &(&1 + 1))
      end)

    separators =
      for index <- 1..@separator_count, do: if(index <= separator_extra, do: "  ", else: " ")

    {widths, separators}
  end

  defp join_cells(cells, separators) do
    cells |> Enum.zip_with(separators ++ [""], &(&1 <> &2)) |> Enum.join()
  end

  defp format_entry(entry, {widths, separators}) do
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

    cells = fit_cells(values, widths)

    cells =
      case entry.latest do
        {:error, _reason} -> List.update_at(cells, @latest, &paint_ng/1)
        _ -> cells
      end

    join_cells(cells, separators)
  end

  # The MAC state of the latest attempt
  defp mac_label(%{attempts: 0}), do: "-"
  defp mac_label(%{host: host}), do: ResultLine.mac_label(host, :console)

  # Colors after padding, so ANSI codes do not count toward the width.
  defp paint_ng("NG" <> padding), do: IO.ANSI.red() <> "NG" <> IO.ANSI.reset() <> padding

  defp target_label(host_name, item_name, nil), do: "#{host_name}/#{item_name}"
  defp target_label(host_name, item_name, port), do: "#{host_name}/#{item_name}:#{port}"

  defp format_row(values, {widths, separators}) do
    values |> fit_cells(widths) |> join_cells(separators)
  end

  defp fit_cells(values, widths) do
    values
    |> Enum.zip(widths)
    |> Enum.zip(@alignments)
    |> Enum.map(fn {{value, width}, alignment} -> fit(value, width, alignment) end)
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

  # A wide character that does not fit before the "~" leaves a space after it.
  defp fit(value, width, alignment \\ :left) do
    if DisplayWidth.width(value) > width do
      DisplayWidth.pad_trailing(DisplayWidth.take(value, width - 1) <> "~", width)
    else
      case alignment do
        :right -> DisplayWidth.pad_leading(value, width)
        :left -> DisplayWidth.pad_trailing(value, width)
      end
    end
  end
end
