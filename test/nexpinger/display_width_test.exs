defmodule NexPinger.DisplayWidthTest do
  use ExUnit.Case, async: true

  alias NexPinger.DisplayWidth

  test "counts wide characters as two columns" do
    assert DisplayWidth.width("web") == 3
    assert DisplayWidth.width("ルーター") == 8
    assert DisplayWidth.width("本社-gw") == 7
    assert DisplayWidth.width("ＡＢ") == 4
    assert DisplayWidth.width("서버") == 4
  end

  test "counts half-width katakana and combining marks as one column" do
    assert DisplayWidth.width("ｻｰﾊﾞ") == 4
    assert DisplayWidth.width("é") == 1
  end

  test "counts emoji as two columns" do
    assert DisplayWidth.width("🚀") == 2
    assert DisplayWidth.width("❤️") == 2
  end

  test "pads to a column width" do
    assert DisplayWidth.pad_trailing("本社", 6) == "本社  "
    assert DisplayWidth.pad_leading("本社", 6) == "  本社"
    assert DisplayWidth.pad_trailing("本社", 3) == "本社"
  end

  test "takes the longest prefix that fits" do
    assert DisplayWidth.take("本社サーバ", 5) == "本社"
    assert DisplayWidth.take("本社サーバ", 6) == "本社サ"
    assert DisplayWidth.take("abc", 5) == "abc"
  end
end
