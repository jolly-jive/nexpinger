defmodule NexPinger.UdpProbeTest do
  use ExUnit.Case, async: true

  alias NexPinger.UdpProbe

  describe "payload/1" do
    test "dns: . SOA with RD=0 and no EDNS" do
      assert <<_id::16, 0::16, 1::16, 0::16, 0::16, 0::16, 0, 6::16, 1::16>> =
               UdpProbe.payload(:dns)
    end

    test "ntp: 48-byte NTPv4 client request" do
      packet = UdpProbe.payload(:ntp)
      assert byte_size(packet) == 48
      assert <<0::2, 4::3, 3::3, _::binary>> = packet
    end

    test "quic: 1200-byte Initial with a reserved version" do
      packet = UdpProbe.payload(:quic)
      assert byte_size(packet) == 1200

      assert <<1::1, 1::1, 0::2, _::4, 0x1A2A3A4A::32, 8, _dcid::64, 8, _scid::64, _::binary>> =
               packet
    end
  end

  describe "probe/4" do
    test "any reply is OK, whatever its content" do
      {:ok, server} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(server)

      Task.start(fn ->
        {:ok, {ip, client_port, _packet}} = :gen_udp.recv(server, 0, 2000)
        :gen_udp.send(server, ip, client_port, "garbage")
      end)

      assert {:ok, rtt} = UdpProbe.probe("127.0.0.1", :dns, port, 1000)
      assert is_float(rtt)
    end

    test "no reply is a timeout" do
      {:ok, server} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(server)

      assert UdpProbe.probe("127.0.0.1", :ntp, port, 100) == {:error, "timeout"}
    end

    test "a closed port is port unreachable" do
      {:ok, server} = :gen_udp.open(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(server)
      :gen_udp.close(server)

      assert UdpProbe.probe("127.0.0.1", :dns, port, 1000) == {:error, "port unreachable"}
    end

    test "an unknown host" do
      assert UdpProbe.probe("no-such-host.invalid", :dns, 53, 100) == {:error, "unknown host"}
    end
  end
end
