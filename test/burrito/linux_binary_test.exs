defmodule NexPinger.Burrito.LinuxBinaryTest do
  @moduledoc """
  Runs the Linux Burrito binary on a pseudo terminal (`script`) and sends it keys and signals.
  Excluded by default. Build the binary for this machine's CPU first, then:

      MIX_ENV=prod BURRITO_TARGET=linux_x86_64 mix release --overwrite
      mix test --only burrito

  On aarch64, the binary is `burrito_out/nexpinger_linux_aarch64`.
  """

  use ExUnit.Case, async: false

  @moduletag :burrito
  @moduletag timeout: 60_000

  @leave_stats_screen "\e[?25h\e[?1049l"

  # The kernel cuts process names (/proc/PID/comm) to 15 bytes
  @launcher_comm "nexpinger_linux"

  # The binary for this machine's CPU, e.g. burrito_out/nexpinger_linux_x86_64
  defp binary do
    [cpu | _] = :erlang.system_info(:system_architecture) |> to_string() |> String.split("-")
    Path.expand("burrito_out/nexpinger_linux_#{cpu}")
  end

  setup_all do
    unless :os.type() == {:unix, :linux}, do: flunk("Linux only")
    unless File.exists?(binary()), do: flunk("#{binary()} not found; build it first")
    unless System.find_executable("script"), do: flunk("script (util-linux) not found")

    dir =
      Path.join(System.tmp_dir!(), "nexpinger-burrito-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # Burrito does not unpack over an install of the same version, so use a fresh install dir
    %{dir: dir, install_dir: Path.join(dir, "install")}
  end

  setup %{dir: dir} do
    # A unique config path: also used to find the processes of this test
    config = Path.join(dir, "hosts-#{System.unique_integer([:positive])}.yml")

    # A closed local port: gives a result every second without any network
    File.write!(config, """
    hosts:
      - name: local
        address: 127.0.0.1
        items:
          - name: closed
            type: tcp
            port: 9
    """)

    on_exit(fn -> System.cmd("pkill", ["-KILL", "-f", config]) end)
    %{config: config}
  end

  test "Tab shows the stats screen and Q quits", context do
    port = start(context)

    output = await(port, "", " TCP ")
    Port.command(port, "\t")
    output = await(port, output, "Ping Statistics")
    # 130 columns: the 120-column layout, so the terminal size was read
    output = await(port, output, String.duplicate("-", 120))

    Port.command(port, "q")
    output = await(port, output, "EXIT=0")
    output = await(port, output, "STTY_END")

    assert output =~ @leave_stats_screen
    assert cooked?(output)
    assert pids(context) == []
  end

  test "stops the BEAM when only the launcher gets SIGTERM", context do
    port = start(context)

    output = await(port, "", " TCP ")
    Port.command(port, "\t")
    output = await(port, output, "Ping Statistics")

    %{launcher: launcher, beam: beam} = processes(context)
    System.cmd("kill", ["-TERM", launcher])

    output = await(port, output, "STTY_END")
    assert wait_until(fn -> not alive?(beam) end)

    # The BEAM restores the terminal by itself, after the shell's `stty -a`
    assert wait_until(fn -> cooked_tty?(context) end)
    output = drain(port, output)
    assert output =~ @leave_stats_screen
  end

  test "stops quietly when the launcher and the BEAM get SIGTERM", context do
    port = start(context)

    output = await(port, "", " TCP ")
    Port.command(port, "\t")
    output = await(port, output, "Ping Statistics")

    %{launcher: launcher, beam: beam} = processes(context)
    System.cmd("kill", ["-TERM", launcher, beam])

    output = await(port, output, "STTY_END")
    assert wait_until(fn -> not alive?(beam) end)
    output = drain(port, output)

    refute output =~ "epipe"
    refute output =~ "SIGTERM received"
    assert output =~ @leave_stats_screen
    assert wait_until(fn -> cooked_tty?(context) end)
  end

  # Does not tell +Bd from the launcher watch: the BREAK menu would go to the
  # broken stdout pipe, and either one stops the BEAM.
  test "Ctrl+C outside raw mode stops the BEAM", context do
    port = start(context, ["--no-stdout"])

    await(port, "", String.duplicate("-", 60))
    %{beam: beam} = processes(context)

    # The terminal is in cooked mode: Ctrl+C becomes SIGINT for the launcher and the BEAM
    Port.command(port, <<3>>)

    assert wait_until(fn -> not alive?(beam) end)
    assert wait_until(fn -> pids(context) == [] end)
  end

  # Runs the binary in a shell on a new pseudo terminal. The shell then prints the exit status
  # and the terminal settings.
  defp start(context, options \\ []) do
    tty_file = tty_file(context)

    command =
      Enum.join(
        [
          "tty > #{tty_file}",
          "stty cols 130 rows 40",
          Enum.join([binary() | options] ++ [context.config], " "),
          "echo EXIT=$?",
          "stty -a",
          "echo STTY_END",
          # Keep the terminal open for checks after the binary is gone
          "sleep 5"
        ],
        "; "
      )

    Port.open({:spawn_executable, System.find_executable("script")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ["-qec", command, "/dev/null"],
      env: [{~c"NEXPINGER_INSTALL_DIR", String.to_charlist(context.install_dir)}]
    ])
  end

  defp tty_file(context), do: context.config <> ".tty"

  defp await(port, output, pattern) do
    if output =~ pattern do
      output
    else
      receive do
        {^port, {:data, data}} ->
          await(port, output <> data, pattern)

        {^port, {:exit_status, status}} ->
          flunk("exited (#{status}) before #{inspect(pattern)}:\n#{output}")
      after
        20_000 -> flunk("no #{inspect(pattern)} in:\n#{output}")
      end
    end
  end

  # Collects what is left to read
  defp drain(port, output) do
    receive do
      {^port, {:data, data}} -> drain(port, output <> data)
    after
      300 -> output
    end
  end

  defp wait_until(check, tries \\ 50) do
    cond do
      check.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(100)
        wait_until(check, tries - 1)
    end
  end

  # PIDs of the launcher and the BEAM: both have the config path in their arguments
  defp pids(context) do
    case System.cmd("pgrep", ["-f", context.config]) do
      {output, 0} ->
        output |> String.split() |> Enum.filter(&(comm(&1) in [@launcher_comm, "beam.smp"]))

      {_output, _status} ->
        []
    end
  end

  defp processes(context) do
    assert wait_until(fn -> length(pids(context)) == 2 end)
    pids = pids(context)

    %{
      launcher: Enum.find(pids, &(comm(&1) == @launcher_comm)),
      beam: Enum.find(pids, &(comm(&1) == "beam.smp"))
    }
  end

  defp comm(pid) do
    case File.read("/proc/#{pid}/comm") do
      {:ok, name} -> String.trim(name)
      {:error, _reason} -> nil
    end
  end

  defp alive?(pid), do: File.exists?("/proc/#{pid}")

  # `stty -a` prints "icanon" / "echo" when on and "-icanon" / "-echo" when off
  defp cooked?(stty_output) do
    settings =
      stty_output |> String.split("STTY_END") |> hd() |> String.split("EXIT=") |> List.last()

    words = String.split(settings, [" ", ";", "\r", "\n"], trim: true)
    "icanon" in words and "echo" in words
  end

  defp cooked_tty?(context) do
    tty = context |> tty_file() |> File.read!() |> String.trim()

    case System.cmd("stty", ["-F", tty, "-a"], stderr_to_stdout: true) do
      {output, 0} ->
        words = String.split(output, [" ", ";", "\n"], trim: true)
        "icanon" in words and "echo" in words

      {_output, _status} ->
        false
    end
  end
end
