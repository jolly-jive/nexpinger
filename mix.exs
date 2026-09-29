defmodule ExPingNext.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_ping_next,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :eex],
      mod: {ExPingNext.Application, []}
    ]
  end

  defp deps do
    [
      {:yaml_elixir, "~> 2.9"},
      {:burrito, "~> 1.0", runtime: false}
    ]
  end

  defp escript do
    [main_module: ExPingNext.CLI, name: "exping_next"]
  end

  defp releases do
    [
      exping_next: [
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
