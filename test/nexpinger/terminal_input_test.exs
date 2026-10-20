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

  # Returns the keys one by one, then :eof
  defp reader(keys) do
    {:ok, agent} = Agent.start_link(fn -> keys end)

    read = fn ->
      Agent.get_and_update(agent, fn
        [key | rest] -> {{:ok, key}, rest}
        [] -> {:eof, []}
      end)
    end

    {read, agent}
  end

  defp unread(agent), do: Agent.get(agent, & &1)

  describe "input_loop/1" do
    test "quits on q, Q and Ctrl+C" do
      for key <- ["q", "Q", <<3>>] do
        {read, agent} = reader(["x", key, "z"])
        assert TerminalInput.input_loop(read) == :quit
        assert unread(agent) == ["z"]
      end
    end

    test "handles the key after a lone ESC as a key of its own" do
      {read, agent} = reader(["\e", "q", "z"])
      assert TerminalInput.input_loop(read) == :quit
      assert unread(agent) == ["z"]

      {read, agent} = reader(["\e", "\e", "q", "z"])
      assert TerminalInput.input_loop(read) == :quit
      assert unread(agent) == ["z"]
    end

    test "handles the key after ESC [ as a key of its own unless it is an arrow" do
      {read, agent} = reader(["\e", "[", "q", "z"])
      assert TerminalInput.input_loop(read) == :quit
      assert unread(agent) == ["z"]

      {read, agent} = reader(["\e", "[", "A", "\e", "[", "B", "q", "z"])
      assert TerminalInput.input_loop(read) == :quit
      assert unread(agent) == ["z"]
    end

    test "quits when the input ends, also inside an escape sequence" do
      assert TerminalInput.input_loop(fn -> {:error, :enotsup} end) == :quit

      for keys <- [[], ["\e"], ["\e", "["]] do
        {read, _agent} = reader(keys)
        assert TerminalInput.input_loop(read) == :quit
      end
    end
  end

  describe "interrupt_loop/1" do
    test "quits on Ctrl+C only" do
      {read, _agent} = reader(["\t", "q", "Q", <<3>>])
      assert TerminalInput.interrupt_loop(read) == :quit
    end

    test "is unavailable when the input ends" do
      {read, _agent} = reader(["q"])
      assert TerminalInput.interrupt_loop(read) == :unavailable
      assert TerminalInput.interrupt_loop(fn -> {:error, :enotsup} end) == :unavailable
    end
  end

  test "restore/0 does nothing when raw mode was not entered" do
    assert TerminalInput.restore() == :ok
  end
end
