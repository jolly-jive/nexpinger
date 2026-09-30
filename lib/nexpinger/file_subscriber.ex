defmodule NexPinger.FileSubscriber do
  @moduledoc """
  Broadcaster 経由で届いた監視結果をファイルへ書き込む subscriber.

  出力形式は `:text`（画面と同じ固定幅テキスト）、`:tsv`（タブ区切りの生データ）、
  `:jsonl`（1行1レコードの JSON）から選ぶ。
  """

  use GenServer

  alias NexPinger.{Host, Item, Timestamp}

  @type format :: :text | :tsv | :jsonl

  @formats [:text, :tsv, :jsonl]

  @fields ~w(timestamp host address mac item type port status rtt_ms error)

  @spec formats() :: [format()]
  def formats, do: @formats

  def start_link(path \\ "monitor.log", name \\ __MODULE__, owner \\ nil, format \\ :text)
      when format in @formats do
    GenServer.start_link(__MODULE__, {path, format, owner}, name: name)
  end

  @impl true
  def init({path, format, owner}) do
    File.mkdir_p!(Path.dirname(path))
    File.touch!(path)

    # 既存ファイルへの追記時はヘッダを重ねない
    if format == :tsv and File.stat!(path).size == 0 do
      append_line(path, tsv_header())
    end

    {:ok, %{path: path, format: format, owner: owner}}
  end

  @impl true
  def handle_info(
        {:item_result, %Host{} = host, %Item{} = item, result},
        %{path: path, format: format, owner: owner} = state
      ) do
    append_line(path, format_record(format, Timestamp.now(), host, item, result))
    notify_owner(owner, {:file_written, path})
    {:noreply, state}
  end

  @doc """
  1件の監視結果を、指定形式の1行（末尾改行付き）に整形する。
  """
  @spec format_record(
          format(),
          String.t(),
          Host.t(),
          Item.t(),
          {:ok, number()} | {:error, term()}
        ) ::
          iodata()
  def format_record(:text, timestamp, host, item, {:ok, rtt_ms}) do
    [
      timestamp,
      " | ",
      format_label(host, item),
      status_tag(:ok),
      " ",
      :io_lib.format("~7.2f ms", [rtt_ms]),
      "\n"
    ]
  end

  def format_record(:text, timestamp, host, item, {:error, reason}) do
    [
      timestamp,
      " | ",
      format_label(host, item),
      status_tag(:ng),
      " ",
      reason_string(reason),
      "\n"
    ]
  end

  def format_record(:tsv, timestamp, host, item, result) do
    values =
      Enum.map(record_values(timestamp, host, item, result), fn
        nil -> ""
        value -> value |> value_string() |> String.replace(["\t", "\r", "\n"], " ")
      end)

    [Enum.join(values, "\t"), "\n"]
  end

  def format_record(:jsonl, timestamp, host, item, result) do
    # キー順を仕様どおりに保つため、オブジェクトは自前で組み立てて値のエンコードだけ JSON に任せる
    pairs =
      @fields
      |> Enum.zip(record_values(timestamp, host, item, result))
      |> Enum.map_join(",", fn {key, value} -> JSON.encode!(key) <> ":" <> JSON.encode!(value) end)

    ["{", pairs, "}\n"]
  end

  @doc false
  def tsv_header, do: [Enum.join(@fields, "\t"), "\n"]

  defp record_values(timestamp, %Host{} = host, %Item{} = item, result) do
    {status, rtt_ms, error} =
      case result do
        {:ok, rtt_ms} -> {"ok", rtt_ms, nil}
        {:error, reason} -> {"ng", nil, reason_string(reason)}
      end

    [
      timestamp,
      host.name,
      host.address,
      host.mac_address,
      item.name,
      Atom.to_string(item.type),
      item.port,
      status,
      rtt_ms,
      error
    ]
  end

  defp value_string(value) when is_binary(value), do: value
  defp value_string(value) when is_float(value), do: Float.to_string(value)
  defp value_string(value), do: to_string(value)

  defp reason_string(reason) when is_binary(reason), do: reason
  defp reason_string(reason), do: inspect(reason)

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
end
