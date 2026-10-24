defmodule NexPinger.ErrorQueueTest do
  use ExUnit.Case, async: true

  alias NexPinger.ErrorQueue

  # struct sock_extended_err as Linux returns it; errno 113 = EHOSTUNREACH, 111 = ECONNREFUSED
  defp extended_err(errno, origin, type, code),
    do: <<errno::native-32, origin, type, code, 0, 0::32, 0::32, 2::native-16, 0::112>>

  describe "classify/1" do
    test "ICMP Time Exceeded in transit is ttl_expired" do
      assert ErrorQueue.classify(extended_err(113, 2, 11, 0)) == :ttl_expired
    end

    test "ICMPv6 Time Exceeded (hop limit) is ttl_expired" do
      assert ErrorQueue.classify(extended_err(113, 3, 3, 0)) == :ttl_expired
    end

    test "fragment reassembly time exceeded is not a TTL expiry" do
      assert ErrorQueue.classify(extended_err(113, 2, 11, 1)) == :other
      assert ErrorQueue.classify(extended_err(113, 3, 3, 1)) == :other
    end

    test "Destination Unreachable is other" do
      assert ErrorQueue.classify(extended_err(111, 2, 3, 3)) == :other
      assert ErrorQueue.classify(extended_err(113, 2, 3, 1)) == :other
      # ICMPv6 type 3 is Time Exceeded, but ICMPv4 type 3 is Destination Unreachable
      assert ErrorQueue.classify(extended_err(113, 2, 3, 0)) == :other
    end

    test "a local error or a short binary is other" do
      assert ErrorQueue.classify(extended_err(90, 1, 0, 0)) == :other
      assert ErrorQueue.classify(<<1, 2, 3>>) == :other
    end
  end
end
