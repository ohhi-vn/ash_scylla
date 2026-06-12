# Copyright [2024] AshScylla Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT REQUIRED WARRANTIES OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule Mix.Tasks.AshScylla.Migrate do
  @moduledoc """
  Runs AshScylla schema migrations for all resources or a specific resource.

  This task compares Ash resource definitions against the live ScyllaDB schema
  and executes the necessary DDL statements to bring the schema in sync.

  ## Usage

      # Migrate all resources
      mix ash_scylla.migrate

      # Migrate a specific resource
      mix ash_scylla.migrate --resource MyApp.User

      # Dry run (show what would be executed)
      mix ash_scylla.migrate --dry-run

      # Use a specific repo
      mix ash_scylla.migrate --repo MyApp.Repo

      # Create keyspace before migrating
      mix ash_scylla.migrate --create-keyspace

  ## Options

  - `--repo` - The repo module to use (defaults to auto-detected repo)
  - `--resource` - A specific resource module to migrate
  - `--dry-run` - Print DDL statements without executing them
  - `--create-keyspace` - Create the keyspace before running migrations
  - `--keyspace` - Override the keyspace name
  - `--nodes` - Override the ScyllaDB nodes (comma-separated)
  """

  use Mix.Task

  @shortdoc "Runs AshScylla schema migrations"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          repo: :atom,
          resource: :atom,
          dry_run: :boolean,
          create_keyspace: :boolean,
          keyspace: :string,
          nodes: :string
        ]
      )

    repo = find_repo(opts)

    if Keyword.get(opts, :create_keyspace, false) do
      create_keyspace(repo, opts)
    end

    resources = find_resources(opts)

    if resources == [] do
      Mix.shell().info("No resources found to migrate.")
    else
      migrate_resources(resources, repo, opts)
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

  defp find_resources(opts) do
    case Keyword.get(opts, :resource) do
      nil ->
        find_all_resources()

      resource ->
        [resource]
    end
  end

  defp find_all_resources do
    apps = Mix.Project.apps_paths() || %{}

    for {_app, path} <- apps,
        file <- Path.wildcard(Path.join(path, "lib/**/resources/**/*.ex")),
        module = file_to_module(file),
        module != nil,
        function_exported?(module, :__info__, 1),
        function_exported?(module, :__ash_scylla__, 1),
        do: module
  end

  defp create_keyspace(repo, opts) do
    keyspace = Keyword.get(opts, :keyspace) || repo.keyspace()

    Mix.shell().info("Creating keyspace #{inspect(keyspace)}...")

    case repo.create_keyspace(keyspace) do
      {:ok, _} ->
        Mix.shell().info("Keyspace created successfully.")

      {:error, error} ->
        Mix.shell().error("Failed to create keyspace: #{inspect(error)}")
        Mix.raise("Keyspace creation failed")
    end
  end

  defp migrate_resources(resources, repo, opts) do
    dry_run = Keyword.get(opts, :dry_run, false)

    if dry_run do
      Mix.shell().info("=== DRY RUN ===")
    end

    results =
      Enum.map(resources, fn resource ->
        migrate_resource(resource, repo, dry_run)
      end)

    success_count = Enum.count(results, &(&1 == :ok))
    error_count = Enum.count(results, &(&1 == :error))
    skipped_count = Enum.count(results, &(&1 == :skipped))

    Mix.shell().info("""

    Migration complete:
      #{success_count} migrated
      #{skipped_count} skipped (no changes)
      #{error_count} errors
    """)

    if error_count > 0 do
      Mix.raise("#{error_count} migration(s) failed")
    end
  end

  defp migrate_resource(resource, repo, dry_run) do
    Mix.shell().info("Migrating #{inspect(resource)}...")

    case AshScylla.DataLayer.SchemaMigration.plan(resource, repo) do
      {:ok, []} ->
        Mix.shell().info("  #{inspect(resource)}: no changes needed")
        :skipped

      {:ok, statements} ->
        if dry_run do
          Mix.shell().info(
            "  #{inspect(resource)}: would execute #{length(statements)} statement(s)"
          )

          Enum.each(statements, &Mix.shell().info("    #{&1}"))
          :ok
        else
          case AshScylla.DataLayer.SchemaMigration.migrate(resource, repo) do
            {:ok, _} ->
              Mix.shell().info("  #{inspect(resource)}: migrated successfully")
              :ok

            {:error, reason} ->
              Mix.shell().error("  #{inspect(resource)}: FAILED - #{inspect(reason)}")
              :error
          end
        end
    end
  end
end
