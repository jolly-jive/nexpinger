defmodule NexPinger.LauncherTest do
  use ExUnit.Case, async: true

  alias NexPinger.Launcher

  describe "parse_parent_pid/1" do
    test "takes the ppid field" do
      stat = "4242 (beam.smp) S 4241 4241 4000 34816 4241 4194560 1 2 3\n"
      assert Launcher.parse_parent_pid(stat) == {:ok, "4241"}
    end

    test "allows spaces and parentheses in the process name" do
      stat = "4242 (my (odd) name) R 17 4242 4000 0 -1 4194560\n"
      assert Launcher.parse_parent_pid(stat) == {:ok, "17"}
    end

    test "rejects broken input" do
      assert Launcher.parse_parent_pid("") == {:error, :no_parent_pid}
      assert Launcher.parse_parent_pid("4242 (beam.smp) S") == {:error, :no_parent_pid}
      assert Launcher.parse_parent_pid("4242 (beam.smp) S x y") == {:error, :no_parent_pid}
    end
  end

  describe "watch" do
    setup do
      {:ok, agent} = Agent.start_link(fn -> {:ok, "100"} end)
      test_pid = self()

      opts = [
        parent_pid: fn -> Agent.get(agent, & &1) end,
        on_exit: fn -> send(test_pid, :launcher_gone) end,
        interval: 10
      ]

      %{agent: agent, opts: opts}
    end

    test "does nothing while the parent PID stays the same", %{opts: opts} do
      {:ok, watcher} = Launcher.start_link(opts)

      refute_receive :launcher_gone, 100
      assert Process.alive?(watcher)
    end

    test "calls on_exit when the parent PID changes", %{agent: agent, opts: opts} do
      {:ok, _watcher} = Launcher.start_link(opts)

      Agent.update(agent, fn _ -> {:ok, "1"} end)
      assert_receive :launcher_gone, 500
    end

    test "calls on_exit when the parent PID can no longer be read", %{agent: agent, opts: opts} do
      {:ok, _watcher} = Launcher.start_link(opts)

      Agent.update(agent, fn _ -> {:error, :no_parent_pid} end)
      assert_receive :launcher_gone, 500
    end

    test "does not start without a parent PID", %{opts: opts} do
      opts = Keyword.put(opts, :parent_pid, fn -> {:error, :no_parent_pid} end)
      assert Launcher.start_link(opts) == :ignore
    end
  end
end
