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

      assert {:ok, rtt} = UdpProbe.probe({127, 0, 0, 1}, :dns, port, 1000)
      assert is_float(rtt)
    end

    test "works over IPv6" do
      {:ok, server} =
        :gen_udp.open(0, [:binary, :inet6, active: false, ip: {0, 0, 0, 0, 0, 0, 0, 1}])

      {:ok, port} = :inet.port(server)

      Task.start(fn ->
        {:ok, {ip, client_port, _packet}} = :gen_udp.recv(server, 0, 2000)
        :gen_udp.send(server, ip, client_port, "garbage")
      end)

      assert {:ok, _rtt} = UdpProbe.probe({0, 0, 0, 0, 0, 0, 0, 1}, :dns, port, 1000)
    end

    test "no reply is a timeout" do
      {:ok, server} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(server)

      assert UdpProbe.probe({127, 0, 0, 1}, :ntp, port, 100) == {:error, "timeout"}
    end

    test "a closed port is port unreachable" do
      {:ok, server} = :gen_udp.open(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(server)
      :gen_udp.close(server)

      assert UdpProbe.probe({127, 0, 0, 1}, :dns, port, 1000) == {:error, "port unreachable"}
    end
  end

  # Linux only: the first router returns Time Exceeded, which needs IP_RECVERR to reach the socket
  describe "probe/5 with TTL 1" do
    @describetag :network

    test "IPv4 reports ttl expired, not a timeout" do
      assert UdpProbe.probe({8, 8, 8, 8}, :dns, 53, 2000, ttl: 1) == {:error, "ttl expired"}
    end

    test "IPv6 reports ttl expired, not a timeout" do
      ip = {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}
      assert UdpProbe.probe(ip, :dns, 53, 2000, ttl: 1) == {:error, "ttl expired"}
    end
  end
end
