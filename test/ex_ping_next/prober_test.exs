defmodule ExPingNext.ProberTest do
  use ExUnit.Case, async: true

  alias ExPingNext.Prober

  describe "parse_ping_time/2 on Windows" do
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
        assert Prober.parse_ping_time(output, @windows) == {:ok, rtt}, output
      end
    end

    test "treats a destination unreachable reply as no reply" do
      output = "192.168.1.1 からの応答: 宛先ホストに到達できません。"
      assert Prober.parse_ping_time(output, @windows) == {:error, "no reply"}
    end

    test "works on OEM code page (non UTF-8) output" do
      output = <<"8.8.8.8 ", 0x82, 0xA9, 0x82, 0xE7, ": bytes=32 ", 0x8E, 0x9E, 0x8A, 0xD4, " =3ms TTL=117">>
      assert Prober.parse_ping_time(output, @windows) == {:ok, 3.0}
    end
  end

  describe "parse_ping_time/2 on Unix" do
    test "parses iputils output with LC_ALL=C" do
      output = "64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=0.045 ms"
      assert Prober.parse_ping_time(output, {:unix, :linux}) == {:ok, 0.045}
    end
  end
end
