defmodule NexPinger.TerminalInput do
  @moduledoc """
  Handles stats screen key input in raw mode when a TTY is available.
  Unix: stty. Windows: `:shell.start_interactive({:noshell, :raw})` (OTP 26+).
  Under Burrito on Linux, the BEAM's stdout is a pipe to the launcher, so the
  launcher's stdout decides if a TTY is available.
  """

  alias NexPinger.{ConsoleSubscriber, Launcher}

  @saved {__MODULE__, :saved}

  def available? do
    if windows?(), do: windows_available?(), else: unix_available?()
  end

  defp unix_available? do
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
    case terminal_size() do
      {_rows, columns} when columns >= 120 -> 120
      _ -> 80
    end
  end

  def terminal_height do
    case terminal_size() do
      {rows, _columns} when rows > 0 -> rows
      _ -> 24
    end
  end

  # :io.columns / :io.rows fail when the BEAM's stdout is a pipe (Burrito on Unix); ask stty then.
  defp terminal_size do
    with {:ok, columns} <- :io.columns(),
         {:ok, rows} <- :io.rows() do
      {rows, columns}
    else
      _ -> stty_size()
    end
  rescue
    _error -> nil
  end

  defp stty_size do
    with {:ok, output} <- stty(["size"]) do
      parse_size(output)
    else
      _ -> nil
    end
  end

  @doc "Parses the output of `stty size` (\"ROWS COLUMNS\") into `{rows, columns}`."
  def parse_size(output) do
    with [rows, columns] <- String.split(output),
         {rows, ""} <- Integer.parse(rows),
         {columns, ""} <- Integer.parse(columns) do
      {rows, columns}
    else
      _ -> nil
    end
  end

  def run do
    if windows?(), do: windows_run(), else: unix_run()
  end

  defp unix_run do
    with {:ok, original_settings} <- stty(["-g"]),
         {:ok, device} <- File.open(tty_path(), [:read, :raw, :binary]) do
      :persistent_term.put(@saved, {stty_prefix(), String.trim(original_settings), tty_path()})

      try do
        case stty(["raw", "-echo", "opost"]) do
          {:ok, _output} -> input_loop(fn -> :file.read(device, 1) end)
          {:error, _reason} -> :unavailable
        end
      after
        try do
          ConsoleSubscriber.end_stats_view()
        after
          :persistent_term.erase(@saved)
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

  @doc """
  Restores the terminal from another process, before a halt (Unix).
  Writes to the TTY device, not stdout: under Burrito the stdout pipe may be broken.
  """
  def restore do
    case :persistent_term.get(@saved, nil) do
      {prefix, settings, tty_path} ->
        if ConsoleSubscriber.stats_view?() do
          File.write(tty_path, ConsoleSubscriber.leave_stats_screen())
        end

        System.cmd("stty", prefix ++ [settings], stderr_to_stdout: true)
        :ok

      nil ->
        :ok
    end
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  # Windows has no stty or /proc; use OTP 26+ noshell raw mode.
  defp windows_available? do
    Code.ensure_loaded?(:shell) and function_exported?(:shell, :start_interactive, 1)
  end

  defp windows_run do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok ->
        try do
          input_loop(&read_stdio_char/0)
        after
          try do
            ConsoleSubscriber.end_stats_view()
          after
            :shell.start_interactive({:noshell, :cooked})
          end
        end

      {:error, _reason} ->
        :unavailable
    end
  rescue
    _error -> :unavailable
  end

  @doc """
  Waits for Ctrl+C when key input is not used (Windows only; `:unavailable` elsewhere).

  The Windows VM shows its BREAK menu on a Ctrl+C event (`+Bd` is Unix only), while the
  Burrito launcher just dies. The Burrito binary runs the VM with `+Bc` (see mix.exs),
  which makes Ctrl+C a plain key instead of an event, so read it here.
  """
  def wait_for_interrupt do
    if windows?() and windows_available?() do
      case :shell.start_interactive({:noshell, :raw}) do
        :ok ->
          try do
            interrupt_loop(&read_stdio_char/0)
          after
            :shell.start_interactive({:noshell, :cooked})
          end

        {:error, _reason} ->
          :unavailable
      end
    else
      :unavailable
    end
  rescue
    _error -> :unavailable
  end

  @doc "Reads keys until Ctrl+C (`:quit`). `:unavailable` when the input ends, e.g. stdin is NUL."
  def interrupt_loop(read) do
    case read.() do
      {:ok, <<3>>} -> :quit
      {:ok, _key} -> interrupt_loop(read)
      _ -> :unavailable
    end
  end

  defp read_stdio_char do
    case :io.get_chars(:standard_io, ~c"", 1) do
      :eof -> :eof
      {:error, reason} -> {:error, reason}
      chars -> {:ok, IO.chardata_to_string(chars)}
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  defp input_loop(read) do
    case read.() do
      {:ok, <<9>>} ->
        ConsoleSubscriber.toggle_view()
        input_loop(read)

      {:ok, key} when key in [<<?q>>, <<?Q>>, <<3>>] ->
        :quit

      {:ok, <<27>>} ->
        handle_escape(read)
        input_loop(read)

      {:ok, <<?k>>} ->
        ConsoleSubscriber.scroll(:up)
        input_loop(read)

      {:ok, <<?j>>} ->
        ConsoleSubscriber.scroll(:down)
        input_loop(read)

      {:ok, _key} ->
        input_loop(read)

      {:error, _reason} ->
        :quit

      :eof ->
        :quit
    end
  end

  defp handle_escape(read) do
    with {:ok, <<"[">>} <- read.(),
         {:ok, direction} <- read.() do
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
    with true <- terminal_stdio?() or Launcher.burrito?(),
         {:ok, input_path} <- fd_path(0),
         {:ok, output_path} <- stdout_path(),
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

  defp fd_path(fd, pid \\ System.pid()) do
    case :os.type() do
      {:unix, :linux} -> File.read_link("/proc/#{pid}/fd/#{fd}")
      {:unix, :darwin} -> File.read_link("/dev/fd/#{fd}")
      _ -> {:error, :unsupported_os}
    end
  end

  # Burrito's Unix launcher pipes the BEAM's stdout through itself,
  # so the real stdout is the launcher's (the parent process).
  defp stdout_path do
    if Launcher.burrito?() do
      with {:ok, pid} <- Launcher.parent_pid(), do: fd_path(1, pid)
    else
      fd_path(1)
    end
  end
end
