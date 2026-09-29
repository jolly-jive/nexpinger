defmodule ExPingNext.StatisticsView do
  @moduledoc """
  統計画面の固定幅テキストを生成する。
  """

  alias ExPingNext.Statistics

  @layouts %{
    80 => [16, 6, 5, 6, 8, 6, 6, 6],
    120 => [24, 10, 10, 8, 14, 10, 10, 10]
  }

  @spec render(map(), 80 | 120, pos_integer(), non_neg_integer()) :: String.t()
  def render(statistics, width, height, offset) when width in [80, 120] do
    column_widths = Map.fetch!(@layouts, width)
    entries = Statistics.entries(statistics)
    visible_rows = max(height - 5, 1)
    displayed = entries |> Enum.drop(offset) |> Enum.take(visible_rows)
    finish = min(offset + length(displayed), length(entries))

    lines = [
      fit(
        "ExPing Next - Ping Statistics | RTT: ms | Window: #{statistics.window} attempts",
        width
      ),
      format_row(
        ["Target", "Runs", "Fail", "Loss%", "Latest", "Avg", "P95", "P99"],
        column_widths
      )
      |> fit(width),
      String.duplicate("-", width)
    ]

    row_lines = Enum.map(displayed, &(&1 |> format_entry(column_widths) |> fit(width)))

    footer =
      "Rows #{if entries == [], do: 0, else: offset + 1}-#{finish} of #{length(entries)} | TAB: Ping Results | Up/Down: scroll | Q: quit"

    Enum.join(lines ++ row_lines ++ [fit(footer, width)], "\r\n") <> "\r\n"
  end

  @spec max_offset(non_neg_integer(), 80 | 120, pos_integer()) :: non_neg_integer()
  def max_offset(entry_count, width, height) when width in [80, 120] do
    max(entry_count - max(height - 5, 1), 0)
  end

  defp format_entry(entry, widths) do
    latency = Statistics.latency(entry)
    attempts = entry.attempts

    latest =
      case entry.latest do
        nil -> "-"
        {:ok, rtt_ms} -> "OK " <> format_number(rtt_ms, Enum.at(widths, 4) - 3)
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
      format_count(attempts, Enum.at(widths, 1)),
      format_count(entry.failures, Enum.at(widths, 2)),
      failure_rate,
      latest,
      format_optional_number(latency.average, Enum.at(widths, 5)),
      format_optional_number(latency.p95, Enum.at(widths, 6)),
      format_optional_number(latency.p99, Enum.at(widths, 7))
    ]

    format_row(values, widths, [:left, :right, :right, :right, :left, :right, :right, :right])
  end

  defp target_label(host_name, item_name, nil), do: "#{host_name}/#{item_name}"
  defp target_label(host_name, item_name, port), do: "#{host_name}/#{item_name}:#{port}"

  defp format_row(
         values,
         widths,
         alignments \\ [:left, :left, :left, :left, :left, :left, :left, :left]
       ) do
    values
    |> Enum.zip(widths)
    |> Enum.zip(alignments)
    |> Enum.map_join(" | ", fn {{value, width}, alignment} -> fit(value, width, alignment) end)
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
