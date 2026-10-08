defmodule NexPinger.BroadcasterTest do
  use ExUnit.Case, async: true

  alias NexPinger.Broadcaster

  describe "subscribe/1" do
    test "returns an error when no process has the name" do
      assert Broadcaster.subscribe(:no_such_subscriber) == {:error, :not_found}
    end
  end
end
