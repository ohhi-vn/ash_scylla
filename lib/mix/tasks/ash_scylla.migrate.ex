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
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule Mix.Tasks.AshScylla.Migrate do
  @moduledoc """
  Runs AshScylla schema migrations for all resources or a specific resource.

  This task compares Ash resource definitions against the live ScyllaDB schema
  and executes the necessary DDL statements to bring the schema in sync.

  It also runs schema migration files from `priv/migrations` that use
  `AshScylla.Schema`. These files are executed before resource migrations.

  ## Usage

      # Migrate all resources and schema files
      mix ash_scylla.migrate

      # Migrate a specific resource
      mix ash_scylla.migrate --resource MyApp.User

      # Dry run (show what would be executed)
      mix ash_scylla.migrate --dry-run

      # Use a specific repo
      mix ash_scylla.migrate --repo MyApp.Repo

      # Create keyspace before migrating
      mix ash_scylla.migrate --create-keyspace

      # Only run schema files from priv/migrations
      mix ash_scylla.migrate --schemas-only

  ## Options

  - `--repo` - The repo module to use (defaults to auto-detected repo)
  - `--resource` - A specific resource module to migrate
  - `--dry-run` - Print DDL statements without executing them
  - `--create-keyspace` - Create the keyspace before running migrations
  - `--keyspace` - Override the keyspace name
  - `--nodes` - Override the ScyllaDB nodes (comma-separated)
  - `--schemas-only` - Only run schema files from priv/migrations
  """

  use Mix.Task

  @shortdoc "Runs AshScylla schema migrations"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          repo: :string,
          resource: :string,
          dry_run: :boolean,
          create_keyspace: :boolean,
          keyspace: :string,
          nodes: :string,
          schemas_only: :boolean
        ]
      )

    opts =
      opts
      |> AshScylla.MixHelpers.maybe_atomize(:repo)
      |> AshScylla.MixHelpers.maybe_atomize(:resource)

    repo = find_repo(opts)

    if Keyword.get(opts, :create_keyspace, false) do
      create_keyspace(repo, opts)
    end

    schemas_only = Keyword.get(opts, :schemas_only, false)

    {schema_count, schema_errors} = run_schema_files(repo, opts)

    if schemas_only do
      report_schema_results(schema_count, schema_errors)
    else
      resources = find_resources(opts)
      {resource_count, resource_errors} = migrate_resources(resources, repo, opts)
      report_results(schema_count, schema_errors, resource_count, resource_errors)
    end
  end

  # ── Schema files from priv/migrations ──────────────────────────────────────

  defp run_schema_files(repo, opts) do
    dry_run = Keyword.get(opts, :dry_run, false)

    schema_files =
      ["priv/migrations"]
      |> Enum.flat_map(fn path ->
        path
        |> Path.join("**/*.ex")
        |> Path.wildcard()
      end)
      |> Enum.sort()

    # Also scan umbrella child apps
    child_files =
      case Mix.Project.apps_paths() do
        nil -> []
        apps ->
          for {_app, path} <- apps,
              file <- Path.wildcard(Path.join(path, "priv/migrations/**/*.ex")),
              do: file
      end

    schema_files = (schema_files ++ child_files) |> Enum.sort()

    if schema_files == [] do
      {0, 0}
    else
      Mix.shell().info("Running #{length(schema_files)} schema file(s) from priv/migrations...")

      results =
        Enum.map(schema_files, fn file ->
          run_schema_file(file, repo, dry_run)
        end)

      count = Enum.count(results, &(&1 == :ok))
      errors = Enum.count(results, &(&1 == :error))
      {count, errors}
    end
  end

  defp run_schema_file(file, repo, dry_run) do
    Mix.shell().info("  Schema: #{file}...")

    case load_schema_module(file) do
      {:ok, module} ->
        statements = module.change()

        if statements == [] do
          Mix.shell().info("    (no statements)")
          :ok
        else
          if dry_run do
            Enum.each(statements, &Mix.shell().info("    #{&1}"))
            :ok
          else
            case AshScylla.Migrator.run(repo.nodes(), statements,
                   keyspace: repo.keyspace(),
                   connect_timeout: 10_000
                 ) do
              {:ok, _} ->
                Mix.shell().info("    executed #{length(statements)} statement(s)")
                :ok

              {:error, reason} ->
                Mix.shell().error("    FAILED: #{inspect(reason)}")
                :error
            end
          end
        end

      {:error, reason} ->
        Mix.shell().error("    FAILED to load: #{inspect(reason)}")
        :error
    end
  end

  defp load_schema_module(file) do
    case Code.compile_file(file) do
      [{module, _}] when is_atom(module) ->
        if function_exported?(module, :change, 0) do
          {:ok, module}
        else
          {:error, :no_change_function}
        end

      [] ->
        {:error, :no_module_loaded}

      other ->
        {:error, other}
    end
  rescue
    error -> {:error, error}
  end

  defp report_schema_results(count, errors) do
    Mix.shell().info("""

    Schema migration complete:
      #{count} executed
      #{errors} errors
    """)

    if errors > 0 do
      Mix.raise("#{errors} schema migration(s) failed")
    end
  end

  defp report_results(schema_count, schema_errors, resource_count, resource_errors) do
    total_ok = schema_count + resource_count
    total_errors = schema_errors + resource_errors

    Mix.shell().info("""

    Migration complete:
      #{total_ok} succeeded (#{schema_count} schemas, #{resource_count} resources)
      #{total_errors} errors
    """)

    if total_errors > 0 do
      Mix.raise("#{total_errors} migration(s) failed")
    end
  end

  # ── Repo discovery ─────────────────────────────────────────────────────────

  defp find_repo(opts) do
    case Keyword.get(opts, :repo) do
      nil -> AshScylla.MixHelpers.find_default_repo()
      repo -> repo
    end
  end

  # ── Resource discovery ─────────────────────────────────────────────────────

  defp find_resources(opts) do
    case Keyword.get(opts, :resource) do
      nil -> AshScylla.MixHelpers.find_all_resources()
      resource -> [resource]
    end
  end

  # ── Keyspace creation ──────────────────────────────────────────────────────

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

  # ── Resource migration ─────────────────────────────────────────────────────

  defp migrate_resources(resources, repo, opts) do
    dry_run = Keyword.get(opts, :dry_run, false)

    if dry_run do
      Mix.shell().info("=== DRY RUN ===")
    end

    if resources == [] do
      Mix.shell().info("No resources found to migrate.")
      {0, 0}
    else
      results =
        Enum.map(resources, fn resource ->
          migrate_resource(resource, repo, dry_run)
        end)

      count = Enum.count(results, &(&1 == :ok))
      errors = Enum.count(results, &(&1 == :error))
      {count, errors}
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
