defmodule ExPingNext.ConsoleSubscriber do
  @moduledoc """
  Broadcaster 経由で届いた監視結果をコンソールに出力する subscriber.
  """

  use GenServer

  alias ExPingNext.Host

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_info({:host_result, %Host{} = host, {:ok, rtt_ms}}, state) do
    IO.puts([
      timestamp(),
      " | ",
      format_label(host),
      status_tag(:ok),
      " ",
      :io_lib.format("~7.2f ms", [rtt_ms])
    ])

    {:noreply, state}
  end

  def handle_info({:host_result, %Host{} = host, {:error, reason}}, state) do
    IO.puts([
      timestamp(),
      " | ",
      format_label(host),
      status_tag(:ng),
      " ",
      reason
    ])

    {:noreply, state}
  end

  defp format_label(%Host{name: name, address: address, type: type} = host) do
    type_str = type |> Atom.to_string() |> String.upcase() |> String.pad_trailing(4)

    [
      String.pad_trailing(name, 16),
      "(",
      String.pad_trailing(address, 15),
      ") ",
      mac_label(host),
      type_str,
      " "
    ]
  end

  defp mac_label(%Host{mac_address: nil}), do: String.duplicate(" ", 18)
  defp mac_label(%Host{mac_address: mac}), do: mac <> " "

  defp status_tag(:ok), do: IO.ANSI.green() <> "OK " <> IO.ANSI.reset()
  defp status_tag(:ng), do: IO.ANSI.red() <> "NG " <> IO.ANSI.reset()

  defp timestamp do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:millisecond)
    |> NaiveDateTime.to_string()
  end
end
