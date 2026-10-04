defmodule NexPinger.Launcher do
  @moduledoc """
  Watches the Burrito launcher, the parent process of the BEAM (Linux only).

  The launcher has no signal handling: on SIGTERM it dies and leaves the BEAM
  running. This checks the parent PID on a timer and stops the BEAM when it changes.
  """

  use GenServer

  alias NexPinger.TerminalInput

  @interval 1000

  def burrito?, do: System.get_env("__BURRITO") != nil

  @doc "True when the BEAM runs under the Burrito launcher on Linux."
  def watchable?, do: burrito?() and :os.type() == {:unix, :linux}

  @doc """
  Options: `:parent_pid` (0-arity fun), `:on_exit` (0-arity fun), `:interval` (ms).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "PID of the parent process. Linux only."
  def parent_pid do
    with {:unix, :linux} <- :os.type(),
         {:ok, stat} <- File.read("/proc/#{System.pid()}/stat") do
      parse_parent_pid(stat)
    else
      _ -> {:error, :no_parent_pid}
    end
  end

  @doc """
  Takes the ppid field of /proc/PID/stat: "PID (COMM) STATE PPID ...".
  COMM may contain spaces and parentheses, so split at the last ")".
  """
  def parse_parent_pid(stat) do
    with [_ | _] = parts <- String.split(stat, ")"),
         [_state, ppid | _] <- parts |> List.last() |> String.split(),
         {_pid, ""} <- Integer.parse(ppid) do
      {:ok, ppid}
    else
      _ -> {:error, :no_parent_pid}
    end
  end

  @doc "Restores the terminal and halts. Does not write to stdout: the pipe may be broken."
  def stop do
    TerminalInput.restore()
    System.halt(0)
  end

  @impl true
  def init(opts) do
    parent_pid = Keyword.get(opts, :parent_pid, &parent_pid/0)

    case parent_pid.() do
      {:ok, pid} ->
        state = %{
          pid: pid,
          parent_pid: parent_pid,
          on_exit: Keyword.get(opts, :on_exit, &stop/0),
          interval: Keyword.get(opts, :interval, @interval)
        }

        schedule(state)
        {:ok, state}

      {:error, _reason} ->
        :ignore
    end
  end

  @impl true
  def handle_info(:check, state) do
    if state.parent_pid.() == {:ok, state.pid} do
      schedule(state)
      {:noreply, state}
    else
      state.on_exit.()
      {:stop, :normal, state}
    end
  end

  defp schedule(state), do: Process.send_after(self(), :check, state.interval)
end
