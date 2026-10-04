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

  test "restore/0 does nothing when raw mode was not entered" do
    assert TerminalInput.restore() == :ok
  end
end
