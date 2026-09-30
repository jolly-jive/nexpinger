defmodule NexPinger.TimestampTest do
  use ExUnit.Case, async: true

  alias NexPinger.Timestamp

  test "formats a system time as local time with milliseconds" do
    system_time_ms = 1_790_000_000_123

    {{year, month, day}, {hour, minute, second}} =
      :calendar.system_time_to_local_time(1_790_000_000, :second)

    expected =
      :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B.123", [
        year,
        month,
        day,
        hour,
        minute,
        second
      ])
      |> IO.iodata_to_binary()

    assert Timestamp.format(system_time_ms) == expected
  end

  test "pads milliseconds to three digits" do
    assert Timestamp.format(1_790_000_000_007) =~ ~r/\.007$/
  end

  test "now/0 returns the display format" do
    assert Timestamp.now() =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$/
  end
end
