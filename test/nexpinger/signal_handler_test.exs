defmodule NexPinger.SignalHandlerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias NexPinger.SignalHandler

  # A private event manager: the real :erl_signal_server stays untouched
  setup do
    {:ok, manager} = :gen_event.start_link()
    test_pid = self()
    :ok = :gen_event.add_handler(manager, SignalHandler, fn -> send(test_pid, :terminated) end)
    %{manager: manager}
  end

  test "calls on_term on SIGTERM, without logging", %{manager: manager} do
    log =
      capture_log(fn ->
        :ok = :gen_event.sync_notify(manager, :sigterm)
        assert_receive :terminated
      end)

    assert log == ""
  end

  test "ignores other signals", %{manager: manager} do
    :ok = :gen_event.sync_notify(manager, :sighup)

    refute_receive :terminated, 50
    assert :gen_event.which_handlers(manager) == [SignalHandler]
  end
end
