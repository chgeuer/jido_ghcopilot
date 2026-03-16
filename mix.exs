defmodule Jido.GHCopilot.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/chgeuer/jido_ghcopilot"
  @description "GitHub Copilot CLI adapter for Jido.Harness"

  def project do
    [
      app: :jido_ghcopilot,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Jido.GHCopilot",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: [
        main: "Jido.GHCopilot",
        extras: ["README.md", "CHANGELOG.md", "guides/getting-started.md"],
        formatters: ["html"]
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 90]
      ],
      description: @description,
      package: [
        name: :jido_ghcopilot,
        description: @description,
        files: [
          ".formatter.exs",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "LICENSE",
          "README.md",
          "config",
          "guides",
          "lib",
          "mix.exs",
          "priv"
        ],
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => @source_url}
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      mod: {Jido.GHCopilot.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:zoi, "~> 0.17.1"},
      {:splode, "~> 0.3"},
      {:jido, "~> 2.1", override: true},
      # Not yet on hex.pm — use local sibling checkouts with override
      {:jido_harness, github: "agentjido/jido_harness", override: true},
      {:jido_shell, github: "agentjido/jido_shell", override: true},
      {:jido_vfs, github: "agentjido/jido_vfs", override: true},
      {:sprites, github: "mikehostetler/sprites-ex", override: true},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:doctor, "~> 0.22", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test]},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "git_hooks.install"],
      q: ["quality"],
      quality: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --min-priority higher",
        "dialyzer",
        "doctor --raise"
      ],
      test: ["test --cover --color"],
      "test.watch": ["watch -c \"mix test\""]
    ]
  end
end
