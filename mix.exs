defmodule AshScylla.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_scylla,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.0"},
      {:exandra, "~> 0.9"},
      {:ecto, "~> 3.12"},
      {:ecto_sql, "~> 3.12"},
      {:testcontainers, "~> 2.0", only: [:test, :dev]}
    ]
  end
end
