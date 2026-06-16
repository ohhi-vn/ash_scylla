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
      repo -> validate_repo!(repo)
    end
  end

  defp validate_repo!(repo) do
    # Compile first so child app modules are available (umbrella projects)
    Mix.Task.run("compile", [])

    # Try multiple strategies to find the repo module
    repo = ensure_repo_available(repo)

    has_nodes = function_exported?(repo, :nodes, 0)
    has_keyspace = function_exported?(repo, :keyspace, 0)

    if has_nodes and has_keyspace do
      repo
    else
      app = AshScylla.MixHelpers.app_name()
      missing = [(!has_nodes && "nodes/0") || nil, (!has_keyspace && "keyspace/0") || nil] |> Enum.reject(&is_nil/1)
      behaviours = repo.__info__(:attributes)[:behaviour] || []
      exported = repo.__info__(:functions) |> Enum.map_join(", ", &"#{elem(&1, 0)}/#{elem(&1, 1)}")

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
  rescue
    _error in [UndefinedFunctionError] ->
      app = AshScylla.MixHelpers.app_name()

      Mix.raise("""
      Repo module #{inspect(repo)} is not available.

      To fix this, create a repo module that uses AshScylla.Repo:

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

  # Tries multiple strategies to make the repo module available.
  # In umbrella projects, child app .beam files may not be on the code path
  # when a dependency's mix task runs.
  defp ensure_repo_available(repo) do
    # Strategy 1: Module already loaded in the VM
    case Code.ensure_loaded(repo) do
      {:module, _} -> return_repo(repo)
      {:error, _} -> :ok
    end

    # Strategy 2: Standard code path search
    case Code.ensure_compiled(repo) do
      {:module, _} -> return_repo(repo)
      {:error, _} -> :ok
    end

    # Strategy 3: In umbrella projects, manually add child app ebin dirs
    add_child_app_paths()

    case Code.ensure_compiled(repo) do
      {:module, _} -> return_repo(repo)
      {:error, _} -> :ok
    end

    # Strategy 4: Try loading from all known lib paths
    load_from_lib_paths(repo)

    case Code.ensure_compiled(repo) do
      {:module, _} -> return_repo(repo)
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

  defp return_repo(repo), do: repo

  # In umbrella projects, add child app ebin directories to the code path.
  defp add_child_app_paths do
    build_path = Mix.Project.build_path() |> Path.expand()

    paths =
      case Mix.Project.apps_paths() do
        nil -> []
        apps_paths ->
          apps_paths
          |> Map.keys()
          |> Enum.map(fn app -> Path.join(build_path, "lib/#{app}/ebin") end)
      end

    # Also try the default _build location
    default_ebin = Path.join(build_path, "lib/ebin")
    paths = if File.dir?(default_ebin), do: [default_ebin | paths], else: paths

    paths
    |> Enum.filter(&File.dir?/1)
    |> Enum.each(fn ebin ->
      :code.add_pathsa([ebin])
    end)
  end

  # Last resort: try to find and compile the .ex file directly.
  # In umbrella projects, child apps may be in apps/<app>/lib/ or <app>/lib/.
  defp load_from_lib_paths(repo) do
    # Convert module name to file path: StorageService.Repo -> storage_service/repo
    segments = Module.split(repo)
    file_name = segments |> List.last() |> Macro.underscore()
    dir_path = segments |> Enum.drop(-1) |> Enum.join("/") |> Macro.underscore()
    module_path = Path.join(dir_path, file_name)

    # Build search paths: project lib dirs + umbrella child app lib dirs
    project_paths = AshScylla.MixHelpers.project_lib_paths()

    child_paths =
      case Mix.Project.apps_paths() do
        nil -> []
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
      # Start the repo connection so resources can query live schema
      {:ok, _} = AshScylla.Connection.start_link(
        name: repo,
        nodes: repo.nodes(),
        keyspace: repo.keyspace(),
        connect_timeout: 10_000
      )

      results =
        Enum.map(resources, fn resource ->
          migrate_resource(resource, repo, dry_run)
        end)

      AshScylla.Connection.stop(repo)

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
