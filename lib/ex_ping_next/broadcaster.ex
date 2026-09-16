defmodule ExPingNext.Broadcaster do
  @moduledoc """
  監視結果を複数の出力先へ配信するための責務を持つプロセス。
  """

  use GenServer

  alias ExPingNext.Host

  @type event :: {:ok, float()} | {:error, String.t()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec publish(Host.t(), event()) :: :ok
  def publish(%Host{} = host, event) do
    GenServer.cast(__MODULE__, {:publish, host, event})
  end

  @impl true
  def init(_opts) do
    {:ok, %{subscribers: []}}
  end

  @impl true
  def handle_cast({:publish, host, {:ok, rtt_ms}}, state) do
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

  def handle_cast({:publish, host, {:error, reason}}, state) do
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

  defp format_label(%Host{name: name, address: address, type: type}) do
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
