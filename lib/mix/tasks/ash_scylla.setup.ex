defmodule Mix.Tasks.AshScylla.Setup do
  @moduledoc """
  Sets up the ScyllaDB keyspace for AshScylla.

  This task creates the keyspace configured in your repo if it doesn't exist.
  It follows the `mix ash_scylla.setup` pattern.

  ## Usage

      mix ash_scylla.setup

  ## Options

  - `--repo` - The repo module to use (defaults to the first repo found in your application)

  ## Examples

      # Use default repo
      mix ash_scylla.setup

      # Specify a repo
      mix ash_scylla.setup --repo MyApp.Repo
  """

  use Mix.Task

  @shortdoc "Creates the ScyllaDB keyspace"

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [repo: :atom])

    repo = find_repo(opts)

    Mix.shell().info("Creating keyspace for #{inspect(repo)}...")

    case repo.create_keyspace() do
      {:ok, _} ->
        Mix.shell().info("Keyspace created successfully.")

      {:error, error} ->
        Mix.shell().error("Failed to create keyspace: #{inspect(error)}")
        Mix.raise("Keyspace creation failed")
    end
  end

  defp find_repo(opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        find_default_repo()

      repo ->
        repo
    end
  end

  defp find_default_repo do
    apps = Mix.Project.apps_paths() || %{}

    repos =
      for {_app, path} <- apps,
          file <- Path.wildcard(Path.join(path, "lib/**/repo.ex")),
          module = file_to_module(file),
          module != nil,
          function_exported?(module, :__info__, 1),
          do: module

    case repos do
      [repo | _] ->
        repo

      [] ->
        Mix.raise("No repo found. Specify one with --repo MyApp.Repo")
    end
  end

  defp file_to_module(file) do
    case file |> Path.rootname() |> Path.split() do
      ["lib" | parts] ->
        parts
        |> Enum.join(".")
        |> Macro.camelize()
        |> String.to_atom()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
