defmodule AshScylla.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_scylla,
      version: "0.1.1",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "AshScylla",
      source_url: "https://github.com/ohhi-vn/ash_scylla",
      homepage_url: "https://ohhi.vn",
      docs: docs(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
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
      extras: ["README.md", "USAGE_GUIDE.md", "IMPLEMENTATION_SUMMARY.md", "ERROR_HANDLING.md"],
      groups_for_modules: [
        Core: [
          AshScylla,
          AshScylla.DataLayer,
          AshScylla.Repo,
          AshScylla.Migration
        ],
        "Data Layer Modules": [
          AshScylla.DataLayer.Dsl,
          AshScylla.DataLayer.QueryBuilder,
          AshScylla.DataLayer.Batch,
          AshScylla.DataLayer.MaterializedView,
          AshScylla.DataLayer.Pagination
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
      {:ash, "~> 3.24"},
      {:exandra, "~> 1.0"},
      {:ecto, "~> 3.13"},
      {:ecto_sql, "~> 3.13"},
      {:testcontainers, "~> 2.3", only: [:test, :dev]},
      {:benchee, "~> 1.5", only: [:dev, :test]},
      {:benchee_html, "~> 1.0", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:reactor, "~> 1.0"}
    ]
  end
end
