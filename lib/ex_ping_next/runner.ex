defmodule ExPingNext.Runner do
  @moduledoc """
  1台のホストに対して interval 間隔で probe を繰り返し、
  1行1項目のストリーム形式で標準出力へ結果を出し続ける。
  """

  alias ExPingNext.{Host, Prober}

  @spec loop(Host.t()) :: no_return()
  def loop(%Host{} = host) do
    started_at = System.monotonic_time(:millisecond)
    result = Prober.probe(host)
    print_line(host, result)

    # 実測にかかった時間を差し引いて、なるべく interval 間隔を維持する
    elapsed = System.monotonic_time(:millisecond) - started_at
    Process.sleep(max(0, host.interval - elapsed))

    loop(host)
  end

  defp print_line(host, {:ok, rtt_ms}) do
    IO.puts([
      timestamp(),
      " | ",
      label(host),
      status_tag(:ok),
      " ",
      :io_lib.format("~7.2f ms", [rtt_ms])
    ])
  end

  defp print_line(host, {:error, reason}) do
    IO.puts([
      timestamp(),
      " | ",
      label(host),
      status_tag(:ng),
      " ",
      reason
    ])
  end

  defp label(%Host{name: name, address: address, type: type}) do
    type_str = type |> Atom.to_string() |> String.upcase() |> String.pad_trailing(4)

    [
      String.pad_trailing(name, 16),
      "(",
      String.pad_trailing(address, 15),
      ") ",
      type_str,
      " "
    ]
  end

  defp status_tag(:ok), do: IO.ANSI.green() <> "OK " <> IO.ANSI.reset()
  defp status_tag(:ng), do: IO.ANSI.red() <> "NG " <> IO.ANSI.reset()

  defp timestamp do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:millisecond)
    |> NaiveDateTime.to_string()
  end
end
