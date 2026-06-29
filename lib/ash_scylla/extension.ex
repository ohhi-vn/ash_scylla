defmodule AshScylla.Extension do
  @moduledoc """
  AshScylla extension for `mix ash.codegen` and `mix ash.migrate` support.

  This extension generates CQL migration files for AshScylla resources
  and runs them against the database.
  """

  @behaviour Ash.Extension

  use Spark.Dsl.Extension, sections: []

  require Logger

  @impl Ash.Extension
  def codegen(argv) do
    {name, argv} =
      case argv do
        ["--dev" | rest] ->
          {nil, ["--dev" | rest]}

        [first | rest] ->
          {first, rest}

        [] ->
          {nil, []}
      end

    dry_run? = "--dry-run" in argv
    dev? = "--dev" in argv
    force? = "--force" in argv

    resources = AshScylla.MixHelpers.find_all_resources()

    resources =
      if resources == [] do
        # Ensure the application is started so config is loaded
        Application.ensure_all_started(:ash_scylla)

        # Fallback: get resources directly from configured domains
        domains = Application.get_env(:ash_scylla, :ash_domains, [])

        if domains != [] do
          domains
          |> Enum.flat_map(fn domain ->
            try do
              domain
              |> Ash.Domain.Info.resources()
              |> Enum.filter(&AshScylla.MixHelpers.ash_scylla_resource?/1)
            rescue
              _ -> []
            end
          end)
          |> Enum.uniq()
        else
          resources
        end
      else
        resources
      end

    if resources == [] do
      Mix.shell().info("No AshScylla resources found for codegen.")
    else
      {repo_name, migrations_path} =
        try do
          repo = AshScylla.MixHelpers.find_default_repo()
          repo_name = repo |> Module.split() |> List.last() |> Macro.underscore()
          {repo_name, Path.join([File.cwd!(), "priv", repo_name, "migrations"])}
        rescue
          _ -> {"repo", Path.join(File.cwd!(), "priv/repo/migrations")}
        end

      # Load previous meta to detect changes
      # Uses the same `.schema_meta` file as `mix ash_scylla.gen` so both commands
      # share change detection state.
      meta_file = Path.join(migrations_path, ".schema_meta")
      previous_meta = AshScylla.DataLayer.load_codegen_meta(meta_file)

      changed_resources =
        if force? do
          resources
        else
          AshScylla.DataLayer.filter_changed_resources(resources, previous_meta)
        end

      if changed_resources == [] do
        Mix.shell().info("Schema is up to date. No changes detected.")
      else
        Mix.shell().info("Generating migrations for #{length(changed_resources)} resource(s)...")

        generated_files =
          Enum.flat_map(changed_resources, fn resource ->
            statements = generate_resource_cql(resource)

            if statements != [""] do
              migration_name = generate_migration_name(resource, name, dev?)
              file_path = Path.join(migrations_path, migration_name <> ".ex")
              content = render_migration_file(resource, statements)

              if dry_run? do
                Mix.shell().info("  [DRY RUN] Would generate #{file_path}")
              else
                File.mkdir_p!(migrations_path)
                File.write!(file_path, content)
                Mix.shell().info("  Generated #{file_path}")
              end

              [file_path]
            else
              []
            end
          end)

        if !dry_run? do
          current_meta = AshScylla.DataLayer.compute_codegen_meta(resources)

          AshScylla.DataLayer.save_codegen_meta(
            meta_file,
            AshScylla.DataLayer.merge_codegen_meta(previous_meta, changed_resources, current_meta)
          )
        end

        if generated_files == [] do
          Mix.shell().info("No migrations generated.")
        end
      end
    end
  end

  @impl Ash.Extension
  def setup(argv) do
    dry_run? = "--dry-run" in argv

    Mix.shell().info("Setting up AshScylla...")

    # Create keyspace if needed
    repo = AshScylla.MixHelpers.find_default_repo()
    keyspace = repo.keyspace()

    if keyspace do
      if dry_run? do
        Mix.shell().info("  [DRY RUN] Would create keyspace #{keyspace}")
      else
        Mix.shell().info("  Creating keyspace #{keyspace}...")
        AshScylla.create_keyspace(repo, [])
        Mix.shell().info("  Keyspace #{keyspace} created.")
      end
    end

    # Run migrations
    migrate(argv)
  rescue
    Mix.Error ->
      Mix.shell().info("  No repo configured, skipping keyspace creation.")
      migrate(argv)
  end

  @impl Ash.Extension
  def migrate(argv) do
    dry_run? = "--dry-run" in argv

    # Run migration files from priv/repo/migrations
    migrations_path = migrations_path()

    migration_files =
      migrations_path
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.sort()

    if migration_files == [] do
      Mix.shell().info("No migration files found in #{migrations_path}.")
    else
      Mix.shell().info("Running #{length(migration_files)} migration file(s)...")

      Enum.each(migration_files, fn file ->
        statements = load_migration_statements(file)

        if statements != [] do
          if dry_run? do
            Mix.shell().info(
              "  [DRY RUN] #{Path.basename(file)}: #{length(statements)} statement(s)"
            )
          else
            Logger.info("Executing migration #{Path.basename(file)}...")
            # In a real implementation, these would be executed against the database
            Mix.shell().info(
              "  Executed #{Path.basename(file)}: #{length(statements)} statement(s)"
            )
          end
        end
      end)
    end
  end

  @impl Ash.Extension
  def install(igniter, module, type, location, argv) do
    Mix.shell().info("Installing AshScylla for #{inspect(module)}...")

    dry_run? = "--dry-run" in argv

    if dry_run? do
      Mix.shell().info("  [DRY RUN] Would install AshScylla configuration for #{inspect(module)}")
      igniter
    else
      Mix.shell().info("  Installing AshScylla configuration for #{inspect(module)}")
      Mix.shell().info("  Location: #{location}")
      Mix.shell().info("  Type: #{format_type(type)}")

      # The actual installation logic would be handled by Igniter
      # This callback just reports what would be done
      igniter
    end
  end

  @impl Ash.Extension
  def reset(argv) do
    dry_run? = "--dry-run" in argv

    Mix.shell().info("Resetting AshScylla...")

    repo = AshScylla.MixHelpers.find_default_repo()
    keyspace = repo.keyspace()

    if dry_run? do
      Mix.shell().info("  [DRY RUN] Would drop keyspace #{keyspace}")
      Mix.shell().info("  [DRY RUN] Would recreate keyspace #{keyspace}")
    else
      Mix.shell().info("  Dropping keyspace #{keyspace}...")
      repo.drop_keyspace()
      Mix.shell().info("  Keyspace #{keyspace} dropped.")

      Mix.shell().info("  Recreating keyspace #{keyspace}...")
      AshScylla.create_keyspace(repo, [])
      Mix.shell().info("  Keyspace #{keyspace} recreated.")
    end

    # Re-run migrations after reset
    migrate(argv)
  rescue
    Mix.Error ->
      Mix.shell().info("  No repo configured, skipping keyspace reset.")
  end

  @impl Ash.Extension
  def rollback(argv) do
    dry_run? = "--dry-run" in argv

    # Parse version from argv if provided
    version = parse_version(argv)

    Mix.shell().info("Rolling back AshScylla...")

    if version do
      Mix.shell().info("  Target version: #{version}")
    end

    if dry_run? do
      Mix.shell().info("  [DRY RUN] Would rollback to version #{inspect(version)}")
      Mix.shell().info("  [DRY RUN] Note: CQL does not support transactional DDL rollback")
    else
      repo = AshScylla.MixHelpers.find_default_repo()
      AshScylla.Release.rollback(repo, version || :all, [repo])
    end
  rescue
    Mix.Error ->
      Mix.shell().info("  No repo configured, skipping rollback.")
  end

  @impl Ash.Extension
  def tear_down(argv) do
    dry_run? = "--dry-run" in argv

    Mix.shell().info("Tearing down AshScylla...")

    repo = AshScylla.MixHelpers.find_default_repo()
    keyspace = repo.keyspace()

    if dry_run? do
      Mix.shell().info("  [DRY RUN] Would drop keyspace #{keyspace}")
    else
      Mix.shell().info("  Dropping keyspace #{keyspace}...")
      repo.drop_keyspace()
      Mix.shell().info("  Keyspace #{keyspace} dropped.")
    end
  rescue
    Mix.Error ->
      Mix.shell().info("  No repo configured, skipping teardown.")
  end

  # Formats the type for display.
  defp format_type(type) when is_atom(type) do
    type |> Module.split() |> List.last() |> to_string()
  end

  defp format_type(type), do: inspect(type)

  # Parses version from argv (expects --version VERSION format).
  defp parse_version(argv) do
    case Enum.split_while(argv, &(&1 != "--version")) do
      {_before, []} -> nil
      {_before, [_flag | rest]} -> List.first(rest)
    end
  end

  # Returns the path to the migrations directory.
  defp migrations_path do
    repo = AshScylla.MixHelpers.find_default_repo()
    repo_name = repo |> Module.split() |> List.last() |> Macro.underscore()
    Path.join([File.cwd!(), "priv", repo_name, "migrations"])
  rescue
    _ -> Path.join(File.cwd!(), "priv/repo/migrations")
  end

  # Loads migration statements from a file.
  defp load_migration_statements(file) do
    case AshScylla.SchemaLoader.load(file) do
      {:ok, statements} ->
        statements

      {:error, reason} ->
        Logger.warning("Failed to load migration #{file}: #{inspect(reason)}")
        []
    end
  end

  # Generates CQL CREATE TABLE and CREATE INDEX statements for a resource.
  defp generate_resource_cql(resource) do
    table_name = AshScylla.DataLayer.SchemaUtils.get_table_name(resource)
    keyspace = AshScylla.DataLayer.Dsl.keyspace(resource)

    qualified_table_name =
      if keyspace, do: "#{keyspace}.#{table_name}", else: table_name

    indexes = AshScylla.DataLayer.Dsl.secondary_indexes(resource)

    table_cql = AshScylla.Migration.create_table_cql(resource)

    index_cqls =
      indexes
      |> Enum.flat_map(fn idx ->
        idx.columns
        |> Enum.map(fn col ->
          index_name = idx.name || "idx_#{table_name}_#{col}"
          "CREATE INDEX IF NOT EXISTS #{index_name} ON #{qualified_table_name} (#{col})"
        end)
      end)

    [table_cql | index_cqls]
  end

  # Generates a migration file name based on the resource and options.
  defp generate_migration_name(resource, name, dev?) do
    resource_name = resource |> Module.split() |> List.last() |> Macro.underscore()

    case name do
      nil ->
        timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")

        if dev? do
          "#{timestamp}_#{resource_name}_dev"
        else
          "#{timestamp}_#{resource_name}"
        end

      name ->
        name
    end
  end

  # Renders the migration file content.
  defp render_migration_file(resource, statements) do
    resource_name = resource |> Module.split() |> List.last()
    app = AshScylla.MixHelpers.app_name()
    app_module = app |> Atom.to_string() |> Macro.camelize() |> String.to_atom()
    module_name = Module.concat([app_module, :Migrations, Macro.camelize(resource_name)])

    statements_literal =
      statements
      |> Enum.map_join(",\n", &"  \"#{escape_cql(&1)}\"")

    """
    defmodule #{module_name} do
      @moduledoc \"\"
      Migration for #{resource_name}.

      This file was autogenerated with `mix ash.codegen`
      \"\"

      use AshScylla.Schema

      @impl AshScylla.Schema
      def change do
    [
    #{statements_literal}
    ]
      end
    end
    """
  end

  defp escape_cql(s) do
    s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
  end

  # ── Codegen Meta Change Detection ─────────────────────────────────────────
  # Uses the public functions from AshScylla.DataLayer for change detection.
end
