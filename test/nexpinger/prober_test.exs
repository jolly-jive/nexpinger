defmodule NexPinger.ProberTest do
  use ExUnit.Case, async: true

  alias NexPinger.{Item, Prober}

  describe "probe/2 with TCP" do
    test "connects over IPv4 and IPv6" do
      for {family, ip} <- [inet: {127, 0, 0, 1}, inet6: {0, 0, 0, 0, 0, 0, 0, 1}] do
        {:ok, listen} = :gen_tcp.listen(0, [family, ip: ip])
        {:ok, port} = :inet.port(listen)
        item = %Item{name: "tcp", type: :tcp, port: port}

        assert {:ok, _rtt} = Prober.probe(ip, item), inspect(ip)
        :gen_tcp.close(listen)
      end
    end
  end

  describe "parse_ping_time/3 on Windows" do
    @windows {:win32, :nt}

    test "parses ping.exe output regardless of the display language" do
      outputs = %{
        "Reply from 8.8.8.8: bytes=32 time=10ms TTL=117" => 10.0,
        "8.8.8.8 からの応答: バイト数 =32 時間 =10ms TTL=117" => 10.0,
        "Antwort von 192.168.1.1: Bytes=32 Zeit<1ms TTL=128" => 1.0,
        "Réponse de 8.8.8.8 : octets=32 temps=12 ms TTL=117" => 12.0,
        "Ответ от 8.8.8.8: число байт=32 время=15мс TTL=117" => 15.0
      }

      for {output, rtt} <- outputs do
        assert Prober.parse_ping_time(output, @windows, "8.8.8.8") == {:ok, rtt}, output
      end
    end

    test "treats a destination unreachable reply as no reply" do
      output = "192.168.1.1 からの応答: 宛先ホストに到達できません。"
      assert Prober.parse_ping_time(output, @windows, "8.8.8.8") == {:error, "no reply"}
    end

    test "works on OEM code page (non UTF-8) output" do
      output = <<"8.8.8.8 ", 0x82, 0xA9, 0x82, 0xE7, ": bytes=32 ", 0x8E, 0x9E, 0x8A, 0xD4, " =3ms TTL=117">>
      assert Prober.parse_ping_time(output, @windows, "8.8.8.8") == {:ok, 3.0}
    end
  end

  describe "parse_ping_time/3 on Windows with IPv6" do
    @windows {:win32, :nt}

    test "parses replies without TTL= regardless of the display language" do
      outputs = %{
        "Reply from 2001:db8::1: time=10ms" => 10.0,
        "2001:db8::1 からの応答: 時間 =10ms" => 10.0,
        "Antwort von 2001:db8::1: Zeit<1ms" => 1.0,
        "Réponse de 2001:db8::1 : temps=12 ms" => 12.0
      }

      for {output, rtt} <- outputs do
        assert Prober.parse_ping_time(output, @windows, "2001:db8::1") == {:ok, rtt}, output
      end
    end

    test "ignores the header and statistics lines" do
      output = """
      Pinging 2001:db8::1 with 32 bytes of data:
      Reply from 2001:db8::1: Destination host unreachable.

      Ping statistics for 2001:db8::1:
          Packets: Sent = 1, Received = 1, Lost = 0 (0% loss),
      Approximate round trip times in milli-seconds:
          Minimum = 0ms, Maximum = 0ms, Average = 0ms
      """

      assert Prober.parse_ping_time(output, @windows, "2001:db8::1") == {:error, "no reply"}
    end

    test "parses a full reply" do
      output = """
      Pinging ::1 with 32 bytes of data:
      Reply from ::1: time<1ms

      Ping statistics for ::1:
          Packets: Sent = 1, Received = 1, Lost = 0 (0% loss),
      """

      assert Prober.parse_ping_time(output, @windows, "::1") == {:ok, 1.0}
    end
  end

  describe "parse_ping_time/3 on Unix" do
    test "parses iputils output with LC_ALL=C" do
      output = "64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=0.045 ms"
      assert Prober.parse_ping_time(output, {:unix, :linux}, "127.0.0.1") == {:ok, 0.045}
    end
  end
end
