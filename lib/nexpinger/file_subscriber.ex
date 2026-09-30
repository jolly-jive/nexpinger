defmodule NexPinger.FileSubscriber do
  @moduledoc """
  Broadcaster 経由で届いた監視結果をファイルへ書き込む subscriber.
  """

  use GenServer

  alias NexPinger.{Host, Item}

  def start_link(path \\ "monitor.log", name \\ __MODULE__, owner \\ nil) do
    GenServer.start_link(__MODULE__, {path, owner}, name: name)
  end

  @impl true
  def init({path, owner}) do
    File.mkdir_p!(Path.dirname(path))
    File.touch!(path)
    {:ok, %{path: path, owner: owner}}
  end

  @impl true
  def handle_info(
        {:item_result, %Host{} = host, %Item{} = item, {:ok, rtt_ms}},
        %{path: path, owner: owner} = state
      ) do
    line = [
      timestamp(),
      " | ",
      format_label(host, item),
      status_tag(:ok),
      " ",
      :io_lib.format("~7.2f ms", [rtt_ms]),
      "\n"
    ]

    append_line(path, line)
    notify_owner(owner, {:file_written, path})
    {:noreply, state}
  end

  def handle_info(
        {:item_result, %Host{} = host, %Item{} = item, {:error, reason}},
        %{path: path, owner: owner} = state
      ) do
    line = [timestamp(), " | ", format_label(host, item), status_tag(:ng), " ", reason, "\n"]
    append_line(path, line)
    notify_owner(owner, {:file_written, path})
    {:noreply, state}
  end

  defp append_line(path, line) do
    File.write(path, line, [:append])
    :ok
  end

  defp notify_owner(nil, _message), do: :ok
  defp notify_owner(owner, message), do: send(owner, message)

  defp format_label(%Host{name: name, address: address} = host, %Item{
         name: item_name,
         type: type,
         port: port
       }) do
    type_str = type |> Atom.to_string() |> String.upcase() |> String.pad_trailing(4)
    item_label = if port, do: "#{item_name}:#{port}", else: item_name

    [
      String.pad_trailing("#{name}/#{item_label}", 24),
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

  defp status_tag(:ok), do: "OK "
  defp status_tag(:ng), do: "NG "

  defp timestamp do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:millisecond)
    |> NaiveDateTime.to_string()
  end
end
