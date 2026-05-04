defmodule BasicApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :basic_app,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BasicApp.Application, []}
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_scylla, path: "../../"},
      {:exandra, "~> 0.9"}
    ]
  end
end
