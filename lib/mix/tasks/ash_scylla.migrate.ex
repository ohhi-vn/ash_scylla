# Copyright 2024 AshScylla Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule Mix.Tasks.AshScylla.Migrate do
  @moduledoc """
  Runs pending CQL migrations and applies resource schema changes.

  This task:
  1. Runs any pending migration files from `priv/migrations` that haven't been
     recorded in the schema migrations tracking table
  2. Optionally runs automatic schema migration for all AshScylla resources
     (diffing resource definitions against snapshots)

  ## Usage

      # Run all pending migrations
      mix ash_scylla.migrate

      # Run migrations up to a specific version
      mix ash_scylla.migrate --to 20240101120000

      # Run a specific number of pending migrations
      mix ash_scylla.migrate --step 3

      # Dry run (show what would be executed)
      mix ash_scylla.migrate --dry-run

      # Use a specific repo
      mix ash_scylla.migrate --repo MyApp.Repo

      # Create keyspace before migrating
      mix ash_scylla.migrate --create-keyspace

      # Only run migration files (skip auto-schema migration)
      mix ash_scylla.migrate --migrations-only

      # Only run auto-schema migration (skip migration files)
      mix ash_scylla.migrate --schemas-only

  ## Options

    - `--repo` - The repo module to use (defaults to auto-detected repo)
    - `--dry-run` - Print DDL statements without executing them
    - `--create-keyspace` - Create the keyspace before running migrations
    - `--keyspace` - Override the keyspace name
    - `--nodes` - Override the ScyllaDB nodes (comma-separated)
    - `--step` - Run only N pending migrations
    - `--to` - Run migrations up to and including version
    - `--migrations-only` - Only run migration files, skip auto-schema
    - `--schemas-only` - Only run auto-schema migration, skip files
    - `--quiet` - Suppress output
  """

  use Mix.Task

  @shortdoc "Runs AshScylla schema migrations"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          repo: :string,
          dry_run: :boolean,
          create_keyspace: :boolean,
          keyspace: :string,
          nodes: :string,
          step: :integer,
          to: :integer,
          migrations_only: :boolean,
          schemas_only: :boolean,
          quiet: :boolean,
          resource: :string
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

    migrations_only = Keyword.get(opts, :migrations_only, false)
    schemas_only = Keyword.get(opts, :schemas_only, false)

    {schema_count, schema_errors} =
      if migrations_only do
        {0, 0}
      else
        run_schema_files(repo, opts)
      end

    {resource_count, resource_errors} =
      if schemas_only do
        {0, 0}
      else
        run_auto_schema_migrations(repo, opts)
      end

    if !migrations_only do
      report_results(schema_count, schema_errors, resource_count, resource_errors)
    end
  end

  # ── Repo Discovery ───────────────────────────────────────────────────────

  defp find_repo(opts) do
    case Keyword.get(opts, :repo) do
      nil -> AshScylla.MixHelpers.find_default_repo()
      repo -> validate_repo!(repo)
    end
  end

  defp validate_repo!(repo) do
    # First check if the module is already available (e.g. test support files)
    case Code.ensure_loaded(repo) do
      {:module, _} ->
        validate_repo_functions(repo)

      {:error, _} ->
        # If not available, compile and try again
        Mix.Task.run("compile", [])
        repo = ensure_repo_available(repo)
        validate_repo_functions(repo)
    end
  end

  defp validate_repo_functions(repo) do
    has_nodes = function_exported?(repo, :nodes, 0)
    has_keyspace = function_exported?(repo, :keyspace, 0)

    if has_nodes and has_keyspace do
      repo
    else
      app = AshScylla.MixHelpers.app_name()

      missing =
        [(!has_nodes && "nodes/0") || nil, (!has_keyspace && "keyspace/0") || nil]
        |> Enum.reject(&is_nil/1)

      behaviours = repo.__info__(:attributes)[:behaviour] || []

      exported =
        repo.__info__(:functions) |> Enum.map_join(", ", &"#{elem(&1, 0)}/#{elem(&1, 1)}")

      Mix.raise("""
      Repo module #{inspect(repo)} is missing required functions: #{Enum.join(missing, ", ")}.

      Detected behaviours: #{inspect(behaviours)}
      Exported functions: #{exported}

      Make sure your repo uses AshScylla.Repo:

          defmodule #{inspect(repo)} do
            use AshScylla.Repo,
              otp_app: :#{app}
          end

      And configure it in config/config.exs:

          config :#{app}, #{inspect(repo)},
            nodes: ["127.0.0.1:9042"],
            keyspace: "#{app}_dev"

      Or generate it with:
          mix ash_scylla.gen.repo --repo #{inspect(repo)}
      """)
    end
  end

  # ── Repo Discovery ─────────────────────────────────────────────────────────

  defp ensure_repo_available(repo) do
    case Code.ensure_loaded(repo) do
      {:module, _} -> repo
      {:error, _} -> :ok
    end

    case Code.ensure_compiled(repo) do
      {:module, _} -> repo
      {:error, _} -> :ok
    end

    add_child_app_paths()

    case Code.ensure_compiled(repo) do
      {:module, _} -> repo
      {:error, _} -> :ok
    end

    load_from_lib_paths(repo)

    case Code.ensure_compiled(repo) do
      {:module, _} ->
        repo

      {:error, :nofile} ->
        app = AshScylla.MixHelpers.app_name()

        Mix.raise("""
        Repo module #{inspect(repo)} does not exist.

        Generate it with:
            mix ash_scylla.gen.repo --repo #{inspect(repo)}

        Or create it manually at lib/#{Macro.underscore(inspect(repo))}.ex:

            defmodule #{inspect(repo)} do
              @moduledoc "AshScylla Repo for #{app}."

              use AshScylla.Repo,
                otp_app: :#{app}
            end

        Then add to config/config.exs:
            config :#{app}, #{inspect(repo)},
              nodes: ["127.0.0.1:9042"],
              keyspace: "#{app}_dev"
        """)

      {:error, reason} ->
        Mix.raise("""
        Repo module #{inspect(repo)} could not be loaded: #{inspect(reason)}.

        Make sure the module is compiled and on the code path.
        """)
    end
  end

  defp add_child_app_paths do
    build_path = Mix.Project.build_path() |> Path.expand()

    paths =
      case Mix.Project.apps_paths() do
        nil ->
          []

        apps_paths ->
          apps_paths
          |> Map.keys()
          |> Enum.map(fn app -> Path.join(build_path, "lib/#{app}/ebin") end)
      end

    default_ebin = Path.join(build_path, "lib/ebin")
    paths = if File.dir?(default_ebin), do: [default_ebin | paths], else: paths

    paths
    |> Enum.filter(&File.dir?/1)
    |> Enum.each(fn ebin ->
      :code.add_pathsa([ebin])
    end)
  end

  defp load_from_lib_paths(repo) do
    segments = Module.split(repo)
    file_name = segments |> List.last() |> Macro.underscore()
    dir_path = segments |> Enum.drop(-1) |> Enum.join("/") |> Macro.underscore()
    module_path = Path.join(dir_path, file_name)

    project_paths = AshScylla.MixHelpers.project_lib_paths()

    child_paths =
      case Mix.Project.apps_paths() do
        nil ->
          []

        apps_paths ->
          apps_paths
          |> Map.values()
          |> Enum.map(fn path -> Path.join(path, "lib") end)
      end

    all_paths = project_paths ++ child_paths

    found =
      Enum.find_value(all_paths, fn lib_path ->
        ex_file = Path.join(lib_path, "#{module_path}.ex")

        if File.exists?(ex_file) do
          Mix.shell().info("  Loading repo from: #{ex_file}")
          Code.compile_file(ex_file)
          true
        else
          false
        end
      end)

    if found do
      :ok
    else
      Mix.shell().info("  Searched paths: #{inspect(all_paths)}")
      Mix.shell().info("  Module path: #{module_path}")
    end
  end

  # ── Keyspace Creation ────────────────────────────────────────────────────

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

  # ── Schema Files from priv/migrations ─────────────────────────────────────

  defp run_schema_files(repo, opts) do
    dry_run = Keyword.get(opts, :dry_run, false)
    step = Keyword.get(opts, :step)
    to_version = Keyword.get(opts, :to)

    migration_files = list_migration_files()

    if migration_files == [] do
      if dry_run do
        Mix.shell().info("=== DRY RUN ===")
      end

      Mix.shell().info("No schema files found in #{migrations_path()}.")
      {0, 0}
    else
      if dry_run do
        Mix.shell().info("=== DRY RUN ===")
      end

      Mix.shell().info(
        "Running #{length(migration_files)} schema file(s) from #{migrations_path()}..."
      )

      # Filter by version if --to or --step is specified
      {migration_files, skipped} =
        filter_migrations_by_version(migration_files, to_version, step)

      results =
        Enum.map(migration_files, fn {version, file} ->
          run_schema_file(file, repo, dry_run, version)
        end)

      count = Enum.count(results, &(&1 == :ok))
      errors = Enum.count(results, &(&1 == :error))

      if skipped > 0 do
        Mix.shell().info("  #{skipped} migration(s) skipped by version filter")
      end

      {count, errors}
    end
  end

  defp list_migration_files do
    migrations_dir = migrations_path()

    schema_files =
      migrations_dir
      |> AshScylla.MixHelpers.migration_glob()
      |> Path.wildcard()
      |> Enum.sort()

    child_files =
      case Mix.Project.apps_paths() do
        nil ->
          []

        apps ->
          for {_app, path} <- apps,
              file <-
                Path.wildcard(
                  AshScylla.MixHelpers.migration_glob("priv/repo/migrations")
                  |> then(&Path.join(path, &1))
                ),
              do: file
      end

    (schema_files ++ child_files)
    |> Enum.sort()
    |> Enum.map(&extract_migration_version/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp migrations_path do
    Path.join(File.cwd!(), "priv/repo/migrations")
  end

  defp extract_migration_version(file) do
    base = Path.basename(file)
    root = Path.rootname(base)

    # Extract the migration version from the filename. Supports:
    # - pure numeric: "20260629124004.exs" -> 20260629124004
    # - numeric + suffix: "20260629122559_activity_message_dev.exs" -> 20260629122559
    # - schema-prefixed: "schema20260629124004.exs" -> 20260629124004
    cond do
      # Pure numeric or numeric-with-suffix (original behavior)
      match?({_, _}, Integer.parse(root)) ->
        case Integer.parse(root) do
          {v, _} -> {v, file}
          :error -> nil
        end

      # Schema-prefixed files from `mix ash_scylla.gen` (e.g. "schema20260629124004")
      String.starts_with?(root, "schema") ->
        case Integer.parse(String.trim_leading(root, "schema")) do
          {v, ""} -> {v, file}
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp filter_migrations_by_version(migrations, nil, nil), do: {migrations, 0}

  defp filter_migrations_by_version(migrations, to_version, nil) do
    kept = Enum.filter(migrations, fn {version, _} -> version <= to_version end)
    skipped = length(migrations) - length(kept)
    {kept, skipped}
  end

  defp filter_migrations_by_version(migrations, nil, step) when is_integer(step) do
    kept = Enum.take(migrations, step)
    skipped = length(migrations) - length(kept)
    {kept, skipped}
  end

  defp filter_migrations_by_version(migrations, to_version, step) do
    filtered = Enum.filter(migrations, fn {version, _} -> version <= to_version end)
    kept = Enum.take(filtered, step)
    skipped = length(migrations) - length(kept)
    {kept, skipped}
  end

  defp run_schema_file(file, repo, dry_run, version) do
    Mix.shell().info("  Migration: #{Path.basename(file)} (v#{version})...")

    case load_schema_module(file) do
      {:ok, module} ->
        statements =
          module.change()
          |> AshScylla.Schema.flatten()

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

  # ── Auto-Schema Migration (diff resources against snapshots) ─────────────

  defp run_auto_schema_migrations(repo, opts) do
    dry_run = Keyword.get(opts, :dry_run, false)
    resources = AshScylla.MixHelpers.find_all_resources()

    resources =
      case Keyword.get(opts, :resource) do
        nil -> resources
        resource -> Enum.filter(resources, &(&1 == resource))
      end

    if dry_run do
      Mix.shell().info("=== DRY RUN ===")
    end

    if resources == [] do
      Mix.shell().info("No resources found to migrate.")
      {0, 0}
    else
      # Only start a real connection if not in dry-run mode
      if !dry_run do
        # The repo may already be connected (e.g. after a reset). If so,
        # reuse the existing connection rather than crashing on
        # {:error, {:already_started, _}}.
        case AshScylla.Connection.get_conn(repo) do
          nil ->
            {:ok, _} =
              AshScylla.Connection.start_link(
                name: repo,
                nodes: repo.nodes(),
                keyspace: repo.keyspace(),
                connect_timeout: 10_000
              )

          %AshScylla.Connection{} ->
            :ok
        end

        results =
          Enum.map(resources, fn resource ->
            migrate_resource(resource, repo, dry_run)
          end)

        AshScylla.Connection.stop(repo)

        count = Enum.count(results, &(&1 == :ok))
        errors = Enum.count(results, &(&1 == :error))
        {count, errors}
      else
        # In dry run mode, just report what would be done
        Enum.each(resources, fn resource ->
          Mix.shell().info("  #{inspect(resource)}: would auto-migrate")
        end)

        {0, 0}
      end
    end
  end

  defp migrate_resource(resource, repo, dry_run) do
    Mix.shell().info("Auto-migrating #{inspect(resource)}...")

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

  # ── Reporting ────────────────────────────────────────────────────────────

  defp report_results(schema_count, schema_errors, resource_count, resource_errors) do
    total_ok = schema_count + resource_count
    total_errors = schema_errors + resource_errors

    Mix.shell().info("""

    Migration complete:
      #{total_ok} succeeded (#{schema_count} migration files, #{resource_count} auto-schema)
      #{total_errors} errors
    """)

    if total_errors > 0 do
      Mix.raise("#{total_errors} migration(s) failed")
    end
  end
end
