defmodule AshScylla.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_scylla,
      version: "0.4.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        flags: [:unmatched_returns, :error_handling, :underspecs]
      ],
      name: "AshScylla",
      source_url: "https://github.com/ohhi-vn/ash_scylla",
      homepage_url: "https://ohhi.vn",
      docs: docs(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    extra =
      if Mix.env() == :test do
        [:testcontainer_ex]
      else
        []
      end

    [
      extra_applications: [:logger] ++ extra
    ]
  end

  defp package do
    [
      description: "An Ash Framework data layer for ScyllaDB/Apache Cassandra using Exandra",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/ohhi-vn/ash_scylla",
        "Documentation" => "https://hexdocs.pm/ash_scylla",
        "ScyllaDB" => "https://www.scylladb.com/",
        "Ash Framework" => "https://ash-hq.org/"
      }
    ]
  end

  defp docs do
    [
      main: "AshScylla",
      logo: "assets/logo.svg",
      extras: [
        "README.md",
        "USAGE_GUIDE.md",
        "IMPLEMENTATION_SUMMARY.md",
        "ERROR_HANDLING.md",
        "CHANGELOG.md"
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
          AshScylla.DataLayer.Pagination
        ],
        "Repo Helpers": [
          AshScylla.Repo
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
      {:ash, "~> 3.0"},
      {:exandra, "~> 1.0"},
      {:ecto, "~> 3.13"},
      # ecto_sql is a runtime dependency of exandra (the Ecto adapter for ScyllaDB).
      # AshScylla itself does not use SQL features — this is pulled in transitively.
      {:ecto_sql, "~> 3.13"},
      {:decimal, "~> 3.1", override: true, only: [:dev, :test]},
      {:hackney, "~> 4.2", override: true, only: [:dev, :test]},
      {:testcontainer_ex, "~> 0.3.1", only: [:test, :dev]},
      # {:testcontainer_ex, path: "../testcontainer_ex", only: [:test, :dev]},
      {:benchee, "~> 1.5", only: :dev},
      {:benchee_html, "~> 1.0", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "test.ci": ["credo --strict", "test --exclude integration"],
      test: ["test"],
      "test.unit": ["test --exclude integration"],
      "test.integration": ["test --only integration"]
    ]
  end
end
