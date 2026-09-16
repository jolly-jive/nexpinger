defmodule ExPingNext.Runner do
  @moduledoc """
  1台のホストを監視するアクター。
  監視対象ごとに独立したプロセスが interval ごとに probe を実行する。
  """

  use GenServer

  alias ExPingNext.{Host, Prober}

  @type state :: %{
          host: Host.t(),
          interval: non_neg_integer()
        }

  @spec start_link(Host.t()) :: GenServer.on_start()
  def start_link(%Host{} = host) do
    GenServer.start_link(__MODULE__, host, name: via_name(host.name))
  end

  @spec probe(Host.t()) :: :ok
  def probe(%Host{} = host) do
    GenServer.cast(via_name(host.name), :probe)
  end

  @impl true
  def init(%Host{} = host) do
    schedule_next(host.interval)
    {:ok, %{host: host, interval: host.interval}}
  end

  @impl true
  def handle_info(:probe, %{host: host} = state) do
    result = Prober.probe(host)
    print_line(host, result)
    schedule_next(state.interval)
    {:noreply, state}
  end

  defp schedule_next(interval) do
    Process.send_after(self(), :probe, interval)
  end

  defp via_name(name) do
    {:via, Registry, {ExPingNext.MonitorRegistry, name}}
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
