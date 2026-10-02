defmodule NexPinger.IcmpHelperTest do
  # Not async: replaces the app's named process and app env
  use ExUnit.Case, async: false

  alias NexPinger.IcmpHelper

  # Unix only: the fake helper is a shell script
  @moduletag skip: match?({:win32, _}, :os.type()) && "requires a Unix shell"

  @fake_helper """
  #!/bin/sh
  while read id command address timeout; do
    case "$command $address" in
      "mac 192.0.2.99") echo "$id error not found" ;;
      mac*) echo "$id ok 00:00:5e:00:53:01" ;;
      *unreachable) echo "$id error unreachable" ;;
      *slow) (sleep 0.3; echo "$id ok 300.000") & ;;
      *) echo "$id ok 1.500" ;;
    esac
  done
  wait
  """

  @broken_helper """
  #!/bin/sh
  exit 3
  """

  setup context do
    dir = Path.join(System.tmp_dir!(), "icmp_helper_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "icmp_helper")
    File.write!(path, context[:script] || @fake_helper)
    File.chmod!(path, 0o755)

    Application.put_env(:nexpinger, :icmp_helper_path, path)
    restart_helper()

    on_exit(fn ->
      Application.delete_env(:nexpinger, :icmp_helper_path)
      restart_helper()
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp restart_helper do
    :ok = Supervisor.terminate_child(NexPinger.Supervisor, IcmpHelper)
    {:ok, _pid} = Supervisor.restart_child(NexPinger.Supervisor, IcmpHelper)
  end

  test "returns the RTT and errors reported by the helper" do
    assert IcmpHelper.ping("192.0.2.1", 1000) == {:ok, 1.5}
    assert IcmpHelper.ping("unreachable", 1000) == {:error, "unreachable"}
    assert IcmpHelper.availability() == :ok
  end

  test "matches concurrent responses to their requests by id" do
    slow = Task.async(fn -> IcmpHelper.ping("slow", 1000) end)
    Process.sleep(50)
    assert IcmpHelper.ping("fast", 1000) == {:ok, 1.5}
    assert Task.await(slow) == {:ok, 300.0}
  end

  test "returns the MAC address reported by the helper" do
    assert IcmpHelper.mac("192.0.2.1") == {:ok, "00:00:5e:00:53:01"}
    assert IcmpHelper.mac("192.0.2.99") == {:error, "not found"}
  end

  test "rejects addresses that would break the line protocol" do
    assert IcmpHelper.ping("a b", 1000) == {:error, "invalid address"}
    assert IcmpHelper.ping("", 1000) == {:error, "invalid address"}
    assert IcmpHelper.mac("a b") == {:error, "invalid address"}
  end

  @tag script: @broken_helper
  test "reports unavailable when the helper exits without responding" do
    assert IcmpHelper.ping("192.0.2.1", 1000) == {:error, :unavailable}
    assert IcmpHelper.ping("192.0.2.1", 1000) == {:error, :unavailable}
    assert IcmpHelper.availability() == {:error, "icmp_helper.exe exited with status 3"}
  end

  test "reports unavailable when the helper does not exist" do
    Application.put_env(:nexpinger, :icmp_helper_path, "/nonexistent/icmp_helper.exe")

    assert IcmpHelper.ping("192.0.2.1", 1000) == {:error, :unavailable}
    assert IcmpHelper.availability() == {:error, "icmp_helper.exe not found"}
  end
end
