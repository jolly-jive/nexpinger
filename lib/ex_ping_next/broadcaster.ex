defmodule ExPingNext.Broadcaster do
  @moduledoc """
  監視結果を複数の subscriber へ配信するイベントハブ。
  """

  use GenServer

  alias ExPingNext.Host

  @type event :: {:ok, float()} | {:error, String.t()}
  @type subscriber :: pid() | atom()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec publish(Host.t(), event()) :: :ok
  def publish(%Host{} = host, event) do
    GenServer.cast(__MODULE__, {:publish, host, event})
  end

  @spec subscribe(subscriber()) :: :ok | {:error, :not_found}
  def subscribe(subscriber) when is_pid(subscriber) do
    GenServer.cast(__MODULE__, {:subscribe, subscriber})
  end

  def subscribe(subscriber) when is_atom(subscriber) do
    case Process.whereis(subscriber) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(__MODULE__, {:subscribe, pid})
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{subscribers: []}}
  end

  @impl true
  def handle_cast({:subscribe, subscriber}, %{subscribers: subscribers} = state) do
    {:noreply, %{state | subscribers: Enum.uniq([subscriber | subscribers])}}
  end

  def handle_cast({:publish, host, event}, %{subscribers: subscribers} = state) do
    Enum.each(subscribers, fn subscriber ->
      send(subscriber, {:host_result, host, event})
    end)

    {:noreply, state}
  end
end


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
