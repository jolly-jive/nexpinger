defmodule NexPinger.Timestamp do
  @moduledoc """
  Timestamp string for screen and file output (local time, `2026-09-30 12:00:00.123`).
  """

  @spec now() :: String.t()
  def now, do: format(System.os_time(:millisecond))

  @spec format(integer()) :: String.t()
  def format(system_time_ms) do
    seconds = Integer.floor_div(system_time_ms, 1000)
    millis = Integer.mod(system_time_ms, 1000)

    seconds
    |> :calendar.system_time_to_local_time(:second)
    |> NaiveDateTime.from_erl!({millis * 1000, 3})
    |> NaiveDateTime.to_string()
  end
end
