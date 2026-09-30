defmodule NexPinger.IcmpSocketTest do
  use ExUnit.Case, async: true

  alias NexPinger.IcmpSocket

  describe "build_packet/5 and checksum/1" do
    test "a packet with its checksum filled in verifies to zero" do
      packet = IcmpSocket.build_packet(8, 0x1234, 0x0001, "abcdefghijklmnopqrstuvwabcdefghi", true)

      assert <<8, 0, checksum::16, 0x1234::16, 0x0001::16, _::binary>> = packet
      assert checksum != 0
      assert IcmpSocket.checksum(packet) == 0
    end

    test "handles odd-length data" do
      packet = IcmpSocket.build_packet(8, 0, 7, "abc", true)
      assert IcmpSocket.checksum(packet) == 0
    end

    test "leaves the checksum zero for ICMPv6 (computed by the kernel)" do
      assert <<128, 0, 0::16, _::binary>> = IcmpSocket.build_packet(128, 0, 1, "x", false)
    end
  end

  describe "reply?/4" do
    test "matches the reply type, sequence and payload, ignoring the identifier" do
      reply = <<0, 0, 0xABCD::16, 0x9999::16, 42::16, "payload">>

      assert IcmpSocket.reply?(reply, 0, 42, "payload")
      refute IcmpSocket.reply?(reply, 0, 43, "payload")
      refute IcmpSocket.reply?(reply, 0, 42, "other")
      refute IcmpSocket.reply?(reply, 129, 42, "payload")
      refute IcmpSocket.reply?(<<0, 0>>, 0, 42, "payload")
    end
  end

  # Either result is possible, depending on ping_group_range
  test "pings the loopback address, or reports the socket as unavailable" do
    if match?({:unix, :linux}, :os.type()) do
      case IcmpSocket.ping("127.0.0.1", 1000) do
        {:ok, rtt} -> assert is_float(rtt)
        other -> assert other == {:error, :unavailable}
      end
    end
  end
end
