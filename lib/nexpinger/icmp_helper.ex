defmodule NexPinger.IcmpHelper do
  @moduledoc """
  Windows only. Sends ICMP Echo via a helper that calls IcmpSendEcho2 / Icmp6SendEcho2
  (`priv/bin/icmp_helper.exe`, source `c_src/icmp_helper.c`), kept running as a port.
  Unlike ping.exe, results do not depend on the display language.

  The helper starts on the first request. If it exits after replying, it restarts on the
  next request. If it is missing, fails to start, or exits without ever replying, returns
  `{:error, :unavailable}`; the caller then falls back to the ping command.

  Override the helper path with `config :nexpinger, :icmp_helper_path` (for tests).

  Protocol (one message per line, replies in completion order):

      Request: <id> <address> <timeout_ms>
      Reply:   <id> ok <rtt_ms>
               <id> error <reason>
  """

  use GenServer

  @executable "icmp_helper.exe"

  @type result :: {:ok, rtt_ms :: float()} | {:error, String.t()} | {:error, :unavailable}

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Checks whether the helper works. Returns the reason if not.
  """
  @spec availability() :: :ok | {:error, String.t()}
  def availability do
    with {:ok, _path} <- executable() do
      # Only way to know it runs is to try: ping loopback once
      case ping("127.0.0.1", 1_000) do
        {:error, :unavailable} -> GenServer.call(__MODULE__, :broken_reason)
        _result -> :ok
      end
    end
  catch
    :exit, _reason -> {:error, "icmp helper not running"}
  end

  @spec ping(String.t(), non_neg_integer()) :: result()
  def ping(address, timeout_ms) do
    cond do
      match?({:error, _}, executable()) ->
        {:error, :unavailable}

      String.contains?(address, [" ", "\t", "\r", "\n"]) or address == "" ->
        {:error, "invalid address"}

      true ->
        GenServer.call(__MODULE__, {:ping, address, timeout_ms}, timeout_ms + 5_000)
    end
  catch
    :exit, _reason -> {:error, "icmp helper not responding"}
  end

  defp executable do
    path =
      Application.get_env(:nexpinger, :icmp_helper_path) ||
        Application.app_dir(:nexpinger, Path.join(["priv", "bin", @executable]))

    if File.regular?(path),
      do: {:ok, path},
      else: {:error, "#{Path.basename(path)} not found"}
  rescue
    _error -> {:error, "#{@executable} not found"}
  end

  # ---- GenServer --------------------------------------------------------

  @impl true
  def init(:ok) do
    {:ok, %{port: nil, responded?: false, broken: nil, next_id: 1, pending: %{}}}
  end

  @impl true
  def handle_call(:broken_reason, _from, %{broken: nil} = state), do: {:reply, :ok, state}
  def handle_call(:broken_reason, _from, state), do: {:reply, {:error, state.broken}, state}

  def handle_call({:ping, _address, _timeout_ms}, _from, %{broken: broken} = state)
      when broken != nil do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:ping, address, timeout_ms}, from, state) do
    case ensure_port(state) do
      {:ok, state} ->
        id = state.next_id
        Port.command(state.port, "#{id} #{address} #{timeout_ms}\n")
        {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}

      {:error, reason} ->
        {:reply, {:error, :unavailable}, %{state | broken: reason}}
    end
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    state = %{state | responded?: true}

    with [id, status, detail] <- String.split(line, " ", parts: 3),
         {id, ""} <- Integer.parse(id),
         {from, pending} when not is_nil(from) <- Map.pop(state.pending, id) do
      GenServer.reply(from, parse_result(status, detail))
      {:noreply, %{state | pending: pending}}
    else
      _ -> {:noreply, state}
    end
  end

  # Exited without replying: can't run here (wrong format, blocked by security software, etc.).
  # Fall back to the ping command from now on.
  def handle_info({port, {:exit_status, status}}, %{port: port, responded?: false} = state) do
    Enum.each(state.pending, fn {_id, from} -> GenServer.reply(from, {:error, :unavailable}) end)

    {:noreply,
     %{state | port: nil, pending: %{}, broken: "#{@executable} exited with status #{status}"}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, "icmp helper exited (status #{status})"})
    end)

    {:noreply, %{state | port: nil, responded?: false, pending: %{}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure_port(%{port: nil} = state) do
    with {:ok, path} <- executable() do
      port =
        Port.open({:spawn_executable, path}, [:binary, :exit_status, :use_stdio, {:line, 1024}])

      {:ok, %{state | port: port}}
    end
  rescue
    error -> {:error, "cannot start #{@executable} (#{Exception.message(error)})"}
  end

  defp ensure_port(state), do: {:ok, state}

  defp parse_result("ok", rtt) do
    case Float.parse(rtt) do
      {rtt_ms, _rest} -> {:ok, rtt_ms}
      :error -> {:error, "invalid icmp helper response"}
    end
  end

  defp parse_result("error", reason), do: {:error, reason}
  defp parse_result(_status, _detail), do: {:error, "invalid icmp helper response"}
end
