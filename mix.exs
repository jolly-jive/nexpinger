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

defmodule NexPinger.MixProject do
  use Mix.Project

  def project do
    [
      app: :nexpinger,
      version: "0.1.0",
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
      {:burrito, "~> 1.0", runtime: false}
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
            windows: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
