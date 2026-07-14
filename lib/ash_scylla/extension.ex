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
    AshScylla.MigrationGenerator.generate(parse_codegen_argv(argv))
  end

  @doc """
  Translates the `mix ash.codegen` argv into options for
  `AshScylla.MigrationGenerator.generate/1`.

  Handles both a leading positional migration name and an explicit `--name`
  flag (Ash injects `--name <name>` for the positional argument), plus the
  shared `--dev` / `--dry-run` / `--check` / `--force` flags.
  """
  @spec parse_codegen_argv(Ash.Extension.argv()) :: keyword()
  def parse_codegen_argv(argv) do
    {positional, rest} = take_leading_positional(argv)

    name = positional || extract_name_flag(rest)

    []
    |> maybe_put(:name, name)
    |> maybe_put(:dev, "--dev" in rest)
    |> maybe_put(:dry_run, "--dry-run" in rest)
    |> maybe_put(:check, "--check" in rest)
    |> maybe_put(:force, "--force" in rest)
  end

  defp take_leading_positional([first | rest]) do
    if is_binary(first) and not String.starts_with?(first, "-") do
      {first, rest}
    else
      {nil, [first | rest]}
    end
  end

  defp take_leading_positional(argv), do: {nil, argv}

  defp extract_name_flag(rest) do
    case Enum.split_while(rest, &(&1 != "--name")) do
      {_, ["--name", name | _]} -> name
      _ -> nil
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, false), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

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
    # Keyspace is auto-created by default unless explicitly skipped with --no-keyspace
    create_keyspace? = "--no-keyspace" not in argv

    repo =
      try do
        AshScylla.MixHelpers.find_default_repo()
      rescue
        Mix.Error ->
          nil
      end

    # Auto-create keyspace before running migrations if it doesn't exist.
    # This ensures `mix ash.migrate` works out-of-the-box without requiring
    # a separate `mix chat_service.release.create_keyspace` step.
    if repo && create_keyspace? do
      keyspace = repo.keyspace()

      if keyspace do
        if dry_run? do
          Mix.shell().info("  [DRY RUN] Would create keyspace #{keyspace}")
        else
          Mix.shell().info("  Ensuring keyspace #{keyspace} exists...")

          case AshScylla.create_keyspace(repo, []) do
            :ok ->
              Mix.shell().info("  Keyspace #{keyspace} ready.")

            {:error, reason} ->
              Mix.shell().error("  Failed to create keyspace: #{inspect(reason)}")
          end
        end
      end
    end

    # Run migration files from priv/repo/migrations
    migrations_path = migrations_path()

    migration_files =
      migrations_path
      |> AshScylla.MixHelpers.migration_glob()
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

            if repo do
              nodes = repo.nodes()

              case AshScylla.Migrator.run(nodes, statements, keyspace: repo.keyspace()) do
                {:ok, _results} ->
                  Mix.shell().info(
                    "  Executed #{Path.basename(file)}: #{length(statements)} statement(s)"
                  )

                {:error, {index, reason}} ->
                  Mix.shell().error(
                    "  FAILED #{Path.basename(file)} at statement #{index}: #{inspect(reason)}"
                  )
              end
            else
              Mix.shell().error(
                "  Cannot run migration #{Path.basename(file)}: no repo configured"
              )
            end
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

  # ── Codegen Meta Change Detection ─────────────────────────────────────────
  # Uses the public functions from AshScylla.DataLayer for change detection.
end
