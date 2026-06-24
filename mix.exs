defmodule AshScylla.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_scylla,
      version: "0.12.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_paths: ["test"],
      test_load_filters: [&String.ends_with?(&1, "_test.exs")],
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        flags: [:unmatched_returns, :error_handling, :underspecs]
      ],
      name: "AshScylla",
      source_url: "https://github.com/ohhi-vn/ash_scylla",
      homepage_url: "https://ohhi.vn",
      docs: docs(),
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        tool: Mix.Tasks.Test.Coverage,
        output: "cover",
        summary: [threshold: 85]
      ],
      consolidate_protocols: Mix.env() != :test,
      test_elixirc_options: [debug_info: true]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AshScylla.Application, []}
    ]
  end

  defp package do
    [
      description: "An Ash Framework data layer for ScyllaDB/Apache Cassandra using Xandra",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/ohhi-vn/ash_scylla",
        "Documentation" => "https://hexdocs.pm/ash_scylla",
        "ScyllaDB" => "https://www.scylladb.com/",
        "Ash Framework" => "https://ash-hq.org/"
      },
      files: ~w(lib .formatter.exs mix.exs README* LICENSE*)
    ]
  end

  defp docs do
    [
      main: "AshScylla",
      logo: "assets/logo.svg",
      extras: [
        "README.md",
        "guides/USAGE_GUIDE.md",
        "guides/DEV_GUIDE.md",
        "guides/PRODUCTION_GUIDE.md",
        "guides/IMPLEMENTATION_SUMMARY.md",
        "guides/ERROR_HANDLING.md",
        "guides/CHANGELOG.md"
      ],
      groups_for_modules: [
        Core: [
          AshScylla,
          AshScylla.DataLayer
        ],
        "Schema Helpers": [
          AshScylla.Migration
        ],
        "Data Layer Modules": [
          AshScylla.DataLayer.Dsl,
          AshScylla.DataLayer.QueryBuilder,
          AshScylla.DataLayer.Batch,
          AshScylla.DataLayer.FilterValidator,
          AshScylla.DataLayer.MaterializedView,
          AshScylla.DataLayer.Pagination,
          AshScylla.DataLayer.Udt,
          AshScylla.DataLayer.Collection,
          AshScylla.DataLayer.SchemaMigration,
          AshScylla.DataLayer.Compression,
          AshScylla.DataLayer.QueryOptimizer
        ],
        "Repo Helpers": [
          AshScylla.Repo,
          AshScylla.Release
        ],
        Performance: [
          AshScylla.PreparedStatementCache
        ],
        Observability: [
          AshScylla.Telemetry
        ],
        "Error Handling": [
          AshScylla.Error,
          AshScylla.Error.ScyllaError
        ]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.29"},
      {:xandra, "~> 0.19"},
      {:decimal, "~> 3.1", override: true, only: [:dev, :test]},
      {:hackney, "~> 4.3", override: true, only: [:dev, :test]},
      {:testcontainer_ex, "~> 0.7", only: [:test], runtime: false},
      # {:testcontainer_ex, path: "../testcontainer_ex", only: [:test, :dev]},
      {:benchee, "~> 1.5", only: [:dev, :test]},
      {:benchee_html, "~> 1.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},

      # Code quality
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "test.ci": ["credo --strict", "test --exclude integration"],
      test: ["test --exclude integration"],
      "test.unit": ["test --exclude integration"],
      "test.integration": ["test --only integration"],
      "test.integration.direct": [
        "test --only integration"
      ],
      "test.integration.apple_container": [
        "run --eval \"System.put_env(\"CONTAINER_ENGINE\", \"apple_container\")\"",
        "test --only integration"
      ],
      # Testing & Coverage
      coveralls: ["test --cover", "coveralls.html"],
      # Code Quality
      quality: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end
end
