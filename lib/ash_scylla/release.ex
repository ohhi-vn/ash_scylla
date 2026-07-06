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

defmodule AshScylla.Release do
  @moduledoc """
  Release task helpers for running AshScylla migrations in production
  without Mix installed.

  ## Usage

  Add a module like this to your project:

      defmodule MyApp.Release do
        @app :my_app

        def migrate do
          load_app()

          for repo <- repos() do
            AshScylla.Release.migrate(repo, repos())
          end
        end

        def rollback(repo, version) do
          load_app()
          AshScylla.Release.rollback(repo, version, repos())
        end

        defp repos do
          Application.fetch_env!(@app, :ash_scylla_repos)
        end

        defp load_app do
          Application.load(@app)
        end
      end

  Then in your release:

      bin/my_app eval "MyApp.Release.migrate"

  ## Configuration

  In your config:

      config :my_app, :ash_scylla_repos, [MyApp.Repo]

  Or configure per-repo:

      config :my_app, MyApp.Repo,
        nodes: ["127.0.0.1:9042"],
        keyspace: "my_app_prod"

  ## Migration Flow

  `migrate/3` auto-discovers resources via `AshScylla.MixHelpers.find_all_resources/0`,
  then calls `AshScylla.DataLayer.SchemaMigration.plan/2` and `migrate/2` for each.
  Supports `:dry_run`, `:create_keyspace`, and `:resources` options.

  ## Rollback

  CQL has no transactional DDL rollback. The `rollback/3` function logs a
  warning — users must implement custom rollback logic (DROP TABLE, etc.).
  """

  require Logger

  @doc """
  Runs migrations for all configured repos.

  ## Options

  - `:resources` - List of specific resource modules to migrate (default: all)
  - `:dry_run` - If true, only log statements without executing
  - `:create_keyspace` - Create the keyspace before migrating

  ## Examples

      AshScylla.Release.migrate(MyApp.Repo, [MyApp.Repo])

      AshScylla.Release.migrate(MyApp.Repo, [MyApp.Repo], resources: [MyApp.User])

      AshScylla.Release.migrate(MyApp.Repo, [MyApp.Repo], dry_run: true)
  """
  @spec migrate(module(), [module()], keyword()) :: :ok | {:error, term()}
  def migrate(repo, all_repos, opts \\ []) do
    Logger.info("AshScylla.Release: Starting migration for #{inspect(repo)}")

    # Auto-create keyspace if requested. This must happen before resource
    # migration since table/index/view CQL requires the keyspace to exist.
    if Keyword.get(opts, :create_keyspace, true) do
      Logger.info("AshScylla.Release: Creating keyspace for #{inspect(repo)}")

      case create_keyspace(repo, opts) do
        :ok ->
          Logger.info("AshScylla.Release: Keyspace ready")

        {:error, reason} ->
          Logger.error("AshScylla.Release: Failed to create keyspace: #{inspect(reason)}")
          {:error, "Keyspace creation failed: #{inspect(reason)}"}
      end
    end

    resources = find_resources(all_repos, opts)

    dry_run = Keyword.get(opts, :dry_run, false)

    if dry_run do
      Logger.info("AshScylla.Release: DRY RUN - no changes will be made")
    end

    results =
      Enum.map(resources, fn resource ->
        migrate_resource(repo, resource, dry_run)
      end)

    success_count = Enum.count(results, &(&1 == :ok))
    error_count = Enum.count(results, &(&1 == :error))
    skipped_count = Enum.count(results, &(&1 == :skipped))

    Logger.info("""
    AshScylla.Release: Migration complete for #{inspect(repo)}
      #{success_count} migrated
      #{skipped_count} skipped (no changes)
      #{error_count} errors
    """)

    if error_count > 0 do
      {:error, "#{error_count} migration(s) failed"}
    else
      :ok
    end
  end

  @doc """
  Rolls back a migration to a specific version.

  Since CQL has no transactional DDL, rollback must be handled manually.
  This function provides a framework for rollbacks — users should define
  their own rollback logic based on their migration history.

  ## Examples

      AshScylla.Release.rollback(MyApp.Repo, 20240101000000, [MyApp.Repo])
  """
  @spec rollback(module(), non_neg_integer() | String.t(), [module()]) :: :ok | {:error, term()}
  def rollback(repo, version, _all_repos) do
    Logger.info("AshScylla.Release: Rolling back #{inspect(repo)} to version #{version}")

    # CQL does not support transactional DDL rollback.
    # Users should implement custom rollback logic based on their migration history.
    # This function serves as a placeholder that logs a warning.
    Logger.warning("""
    AshScylla.Release: Automatic rollback is not supported for CQL.
    Please implement custom rollback logic for version #{version}.
    You may need to manually execute DROP TABLE, DROP INDEX, or ALTER TABLE statements.
    """)

    :ok
  end

  @doc """
  Creates the keyspace for a repo if it doesn't exist.

  ## Examples

      AshScylla.Release.create_keyspace(MyApp.Repo)
  """
  @spec create_keyspace(module(), keyword()) :: :ok | {:error, term()}
  def create_keyspace(repo, opts \\ []) do
    Logger.info("AshScylla.Release: Creating keyspace for #{inspect(repo)}")

    case repo.create_keyspace(nil, opts) do
      {:ok, _} ->
        Logger.info("AshScylla.Release: Keyspace created successfully")
        :ok

      {:error, reason} ->
        Logger.error("AshScylla.Release: Failed to create keyspace: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Returns all AshScylla resources for the given repos.

  Scans the application's modules for resources that use AshScylla.DataLayer.
  """
  @spec find_resources([module()], keyword()) :: [module()]
  def find_resources(_all_repos, opts) do
    case Keyword.get(opts, :resources) do
      nil ->
        auto_discover_resources()

      resources when is_list(resources) ->
        resources
    end
  end

  @doc false
  defp auto_discover_resources do
    apps = Application.started_applications()

    for {app, _, _} <- apps,
        modules <- get_app_modules(app),
        module <- modules,
        function_exported?(module, :__ash_scylla__, 1),
        do: module
  rescue
    _ -> []
  end

  defp get_app_modules(app) do
    case :application.get_key(app, :modules) do
      {:ok, modules} when is_list(modules) -> [modules]
      :undefined -> []
    end
  end

  @spec migrate_resource(module(), module(), boolean()) :: :ok | :error | :skipped
  defp migrate_resource(repo, resource, dry_run) do
    Logger.info("AshScylla.Release: Migrating #{inspect(resource)}...")

    case AshScylla.DataLayer.SchemaMigration.plan(resource, repo) do
      {:ok, []} ->
        Logger.info("  #{inspect(resource)}: no changes needed")
        :skipped

      {:ok, statements} ->
        if dry_run do
          Logger.info("  #{inspect(resource)}: would execute #{length(statements)} statement(s)")
          Enum.each(statements, &Logger.info("    #{&1}"))
          :ok
        else
          case AshScylla.DataLayer.SchemaMigration.migrate(resource, repo) do
            {:ok, _} ->
              Logger.info("  #{inspect(resource)}: migrated successfully")
              :ok

            {:error, reason} ->
              Logger.error("  #{inspect(resource)}: FAILED - #{inspect(reason)}")
              :error
          end
        end
    end
  end
end
