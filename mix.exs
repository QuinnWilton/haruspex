defmodule Haruspex.MixProject do
  use Mix.Project

  def project do
    [
      app: :haruspex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      compilers: [:roux] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      test_coverage: [
        threshold: 95,
        ignore_modules: [Haruspex.MixProject]
      ],
      roux: [
        languages: [Haruspex],
        source_dirs: ["examples"]
      ],
      dialyzer: [
        plt_add_apps: [:ex_unit],
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        flags: [:error_handling, :unknown]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:roux, path: "../roux"},
      {:pentiment, path: "../pentiment"},
      {:quail, path: "../quail"},
      {:constrain, path: "../constrain"},
      {:nimble_parsec, "~> 1.4"},
      {:stream_data, "~> 1.2", only: [:test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
