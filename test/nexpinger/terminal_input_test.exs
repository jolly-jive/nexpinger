defmodule NexPinger.TerminalInputTest do
  use ExUnit.Case, async: true

  alias NexPinger.TerminalInput

  describe "parse_size/1" do
    test "parses the output of stty size" do
      assert TerminalInput.parse_size("40 130\n") == {40, 130}
    end

    test "rejects other output" do
      assert TerminalInput.parse_size("") == nil
      assert TerminalInput.parse_size("stty: invalid argument\n") == nil
      assert TerminalInput.parse_size("40 130 5\n") == nil
    end
  end

  describe "interrupt_loop/1" do
    # Returns the keys one by one, then :eof
    defp reader(keys) do
      {:ok, agent} = Agent.start_link(fn -> keys end)

      fn ->
        Agent.get_and_update(agent, fn
          [key | rest] -> {{:ok, key}, rest}
          [] -> {:eof, []}
        end)
      end
    end

    test "quits on Ctrl+C only" do
      assert TerminalInput.interrupt_loop(reader(["\t", "q", "Q", <<3>>])) == :quit
    end

    test "is unavailable when the input ends" do
      assert TerminalInput.interrupt_loop(reader(["q"])) == :unavailable
      assert TerminalInput.interrupt_loop(fn -> {:error, :enotsup} end) == :unavailable
    end
  end

  test "restore/0 does nothing when raw mode was not entered" do
    assert TerminalInput.restore() == :ok
  end
end
