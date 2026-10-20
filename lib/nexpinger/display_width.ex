defmodule NexPinger.DisplayWidth do
  @moduledoc """
  Text width in terminal columns, for padding and cutting fixed-width columns.

  East Asian Wide and Fullwidth characters (CJK, kana, Hangul, fullwidth forms)
  and emoji take 2 columns; everything else takes 1. A grapheme takes the width
  of its first code point, so combining marks add nothing, except half-width
  (semi-)voiced sound marks ("ﾊﾞ"), which take a column of their own.
  Ambiguous-width characters (e.g. "○", Greek, Cyrillic) count as 1, as most
  terminals show them.
  """

  # East Asian Width W and F, main blocks
  @wide [
    0x1100..0x115F,
    0x231A..0x231B,
    0x2329..0x232A,
    0x23E9..0x23EC,
    0x2E80..0x303E,
    0x3041..0x33FF,
    0x3400..0x4DBF,
    0x4E00..0x9FFF,
    0xA000..0xA4CF,
    0xA960..0xA97F,
    0xAC00..0xD7A3,
    0xF900..0xFAFF,
    0xFE10..0xFE19,
    0xFE30..0xFE6F,
    0xFF00..0xFF60,
    0xFFE0..0xFFE6,
    0x1F300..0x1F64F,
    0x1F680..0x1F6FF,
    0x1F900..0x1F9FF,
    0x20000..0x2FFFD,
    0x30000..0x3FFFD
  ]

  @doc """
  The number of columns `text` takes.
  """
  @spec width(String.t()) :: non_neg_integer()
  def width(text) do
    text |> String.graphemes() |> Enum.map(&grapheme_width/1) |> Enum.sum()
  end

  @doc """
  Pads `text` with spaces on the right to `width` columns.
  """
  @spec pad_trailing(String.t(), non_neg_integer()) :: String.t()
  def pad_trailing(text, width), do: text <> padding(text, width)

  @doc """
  Pads `text` with spaces on the left to `width` columns.
  """
  @spec pad_leading(String.t(), non_neg_integer()) :: String.t()
  def pad_leading(text, width), do: padding(text, width) <> text

  @doc """
  The longest prefix of `text` that fits in `width` columns.
  """
  @spec take(String.t(), non_neg_integer()) :: String.t()
  def take(text, width) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {taken, used} ->
      used = used + grapheme_width(grapheme)
      if used <= width, do: {:cont, {[grapheme | taken], used}}, else: {:halt, {taken, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp padding(text, width), do: String.duplicate(" ", max(width - width(text), 0))

  defp grapheme_width(grapheme) do
    [first | rest] = String.to_charlist(grapheme)

    # U+FE0F asks for emoji presentation, shown 2 columns wide
    base = if wide?(first) or 0xFE0F in rest, do: 2, else: 1
    base + Enum.count(rest, &(&1 in 0xFF9E..0xFF9F))
  end

  defp wide?(code_point), do: Enum.any?(@wide, &(code_point in &1))
end
