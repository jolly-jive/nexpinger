defmodule NexPinger.SignalHandler do
  @moduledoc """
  Replaces OTP's signal handler so that SIGTERM stops the BEAM without a log line.

  Under Burrito on Linux, SIGTERM often kills the launcher too. OTP's handler then
  logs "SIGTERM received" to the broken stdout pipe, which prints an :epipe error.
  """

  @behaviour :gen_event

  @doc "`on_term` is a 0-arity fun called on SIGTERM."
  def install(on_term \\ &NexPinger.Launcher.stop/0) do
    :gen_event.swap_handler(
      :erl_signal_server,
      {:erl_signal_handler, []},
      {__MODULE__, on_term}
    )
  end

  @impl true
  def init({on_term, _old_state}), do: {:ok, on_term}
  def init(on_term), do: {:ok, on_term}

  @impl true
  def handle_event(:sigterm, on_term) do
    on_term.()
    {:ok, on_term}
  end

  # Same as OTP's handler
  def handle_event(:sigusr1, _on_term), do: :erlang.halt(~c"Received SIGUSR1")
  def handle_event(:sigquit, _on_term), do: :erlang.halt()
  def handle_event(_signal, on_term), do: {:ok, on_term}

  @impl true
  def handle_call(_request, on_term), do: {:ok, :ok, on_term}
end
