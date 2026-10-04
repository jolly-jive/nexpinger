defmodule Mix.Tasks.Compile.IcmpHelper do
  @moduledoc """
  Cross-compiles the Windows ICMP helper (priv/bin/icmp_helper.exe) with `zig cc`.
  Skipped if zig is missing (Windows then falls back to ping.exe).
  """

  use Mix.Task.Compiler

  @source "c_src/icmp_helper.c"
  @target "priv/bin/icmp_helper.exe"

  @impl true
  def run(_args) do
    zig = System.find_executable("zig")

    cond do
      File.exists?(@target) and not Mix.Utils.stale?([@source], [@target]) ->
        {:noop, []}

      zig == nil ->
        Mix.shell().info("zig not found; skipping #{@target} (Windows falls back to ping.exe)")
        {:noop, []}

      true ->
        build(zig)
    end
  end

  defp build(zig) do
    File.mkdir_p!(Path.dirname(@target))

    args =
      ~w(cc -target x86_64-windows-gnu -O2 -s -o #{@target} #{@source} -liphlpapi -lws2_32)

    # Zig cache fails under /mnt/c on WSL, so default to the temp dir
    env =
      for {name, dir} <- [
            {"ZIG_LOCAL_CACHE_DIR", "zig-cache-nexpinger"},
            {"ZIG_GLOBAL_CACHE_DIR", "zig-global-cache-nexpinger"}
          ],
          System.get_env(name) == nil,
          do: {name, Path.join(System.tmp_dir!(), dir)}

    case System.cmd(zig, args, stderr_to_stdout: true, env: env) do
      {_output, 0} ->
        Mix.shell().info("Compiled #{@target}")
        {:ok, []}

      {output, status} ->
        Mix.raise("zig cc failed with status #{status}:\n#{output}")
    end
  end
end

defmodule NexPinger.BurritoPrune do
  @moduledoc """
  Burrito step (after :patch): removes what the release does not use.

  Burrito copies every DLL / EXE / SO of the target OTP into lib/, used or not
  (crypto with OpenSSL, wx with WebView2, ...). This keeps only the lib dirs
  of the release's apps, and drops ERTS debug builds and PDB files.
  Non-Windows targets also drop the Windows ICMP helper.
  Less to ship, and less third-party code to give notices for.
  """

  # Burrito is prod only, so take the context as a plain map
  def execute(context) do
    keep =
      for {app, props} <- context.mix_release.applications,
          do: "#{app}-#{props[:vsn]}"

    lib_dirs = Path.wildcard(Path.join(context.work_dir, "lib/*"))
    debug_files = Path.wildcard(Path.join(context.work_dir, "erts-*/bin/{*.pdb,beam.debug.*}"))

    for path <- lib_dirs, Path.basename(path) not in keep do
      File.rm_rf!(path)
      Mix.shell().info("Pruned #{Path.relative_to(path, context.work_dir)}")
    end

    Enum.each(debug_files, &File.rm!/1)
    Mix.shell().info("Pruned #{length(debug_files)} ERTS debug files")

    # The ICMP helper is Windows only
    if context.target.os != :windows do
      helpers = Path.wildcard(Path.join(context.work_dir, "lib/nexpinger-*/priv/bin/*.exe"))
      Enum.each(helpers, &File.rm!/1)
      Mix.shell().info("Pruned #{length(helpers)} Windows helpers")
    end

    context
  end
end

defmodule NexPinger.BurritoBreak do
  @moduledoc """
  Burrito step (after :patch): sets the VM's Ctrl+C flag for the target OS.

  rel/vm.args.eex has +Bd, which only the Unix VM honors. The Windows VM gets +Bc:
  Ctrl+C is then no console event (no BREAK menu, and the launcher stays alive)
  but a plain key, which NexPinger.TerminalInput reads.
  """

  def execute(context) do
    if context.target.os == :windows do
      for path <- Path.wildcard(Path.join(context.work_dir, "releases/*/vm.args")) do
        File.write!(path, String.replace(File.read!(path), ~r/^\+Bd$/m, "+Bc"))
        Mix.shell().info("Set +Bc in #{Path.relative_to(path, context.work_dir)}")
      end
    end

    context
  end
end

defmodule NexPinger.MixProject do
  use Mix.Project

  def project do
    [
      app: :nexpinger,
      version: "1.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: Mix.compilers() ++ [:icmp_helper],
      deps: deps(),
      escript: escript(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :eex],
      mod: {NexPinger.Application, []}
    ]
  end

  defp deps do
    [
      {:yaml_elixir, "~> 2.9"},
      # prod only: escript.build embeds every dep of the env, runtime: false or not.
      # Build the escript in another env to keep Burrito and its deps out.
      {:burrito, "~> 1.0", runtime: false, only: :prod}
    ]
  end

  defp escript do
    [main_module: NexPinger.CLI, name: "nexpinger"]
  end

  defp releases do
    [
      nexpinger: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            windows: [os: :windows, cpu: :x86_64],
            linux: [os: :linux, cpu: :x86_64]
          ],
          extra_steps: [patch: [post: [NexPinger.BurritoPrune, NexPinger.BurritoBreak]]]
        ]
      ]
    ]
  end
end
