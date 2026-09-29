defmodule ExPingNext.TerminalInput do
  @moduledoc """
  TTY が利用可能なとき、raw mode で統計画面のキー入力を処理する。
  """

  alias ExPingNext.ConsoleSubscriber

  def available? do
    with true <- stty_prefix() != nil,
         {:ok, _settings} <- stty(["-g"]),
         {:ok, device} <- File.open(tty_path(), [:read, :raw, :binary]) do
      File.close(device)
      true
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  def terminal_width do
    case :io.columns() do
      {:ok, columns} when columns >= 120 -> 120
      _ -> 80
    end
  rescue
    _error -> 80
  end

  def terminal_height do
    case :io.rows() do
      {:ok, rows} when rows > 0 -> rows
      _ -> 24
    end
  rescue
    _error -> 24
  end

  def run do
    with {:ok, original_settings} <- stty(["-g"]),
         {:ok, device} <- File.open(tty_path(), [:read, :raw, :binary]) do
      try do
        case stty(["raw", "-echo", "opost"]) do
          {:ok, _output} -> input_loop(device)
          {:error, _reason} -> :unavailable
        end
      after
        try do
          ConsoleSubscriber.end_stats_view()
        after
          stty([String.trim(original_settings)])
          File.close(device)
        end
      end
    else
      _ -> :unavailable
    end
  rescue
    _error -> :unavailable
  end

  defp input_loop(device) do
    case :file.read(device, 1) do
      {:ok, <<9>>} ->
        ConsoleSubscriber.toggle_view()
        input_loop(device)

      {:ok, <<3>>} ->
        :quit

      {:ok, <<27>>} ->
        handle_escape(device)
        input_loop(device)

      {:ok, <<?k>>} ->
        ConsoleSubscriber.scroll(:up)
        input_loop(device)

      {:ok, <<?j>>} ->
        ConsoleSubscriber.scroll(:down)
        input_loop(device)

      {:ok, _key} ->
        input_loop(device)

      {:error, _reason} ->
        :quit

      :eof ->
        :quit
    end
  end

  defp handle_escape(device) do
    with {:ok, <<"[">>} <- :file.read(device, 1),
         {:ok, direction} <- :file.read(device, 1) do
      case direction do
        <<?A>> -> ConsoleSubscriber.scroll(:up)
        <<?B>> -> ConsoleSubscriber.scroll(:down)
        _ -> :ok
      end
    else
      _ -> :ok
    end
  end

  defp stty(args) do
    case stty_prefix() do
      nil ->
        {:error, :unsupported_terminal}

      prefix ->
        case System.cmd("stty", prefix ++ args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {_output, status} -> {:error, {:stty_failed, status}}
        end
    end
  rescue
    error -> {:error, error}
  end

  defp stty_prefix do
    with true <- terminal_stdio?(),
         {:ok, input_path} <- fd_path(0),
         {:ok, output_path} <- fd_path(1),
         true <- input_path == output_path do
      case :os.type() do
        {:unix, :linux} -> ["-F", input_path]
        {:unix, :darwin} -> ["-f", input_path]
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp tty_path do
    {:ok, path} = fd_path(0)
    path
  end

  defp terminal_stdio? do
    case :io.getopts(:standard_io) do
      options when is_list(options) ->
        Keyword.get(options, :terminal, false) and
          Keyword.get(options, :stdin, false) and
          Keyword.get(options, :stdout, false)

      _ ->
        false
    end
  rescue
    _error -> false
  end

  defp fd_path(fd) do
    case :os.type() do
      {:unix, :linux} -> File.read_link("/proc/#{System.pid()}/fd/#{fd}")
      {:unix, :darwin} -> File.read_link("/dev/fd/#{fd}")
      _ -> {:error, :unsupported_os}
    end
  end
end
