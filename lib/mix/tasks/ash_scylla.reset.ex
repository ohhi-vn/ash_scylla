defmodule Mix.Tasks.AshScylla.Reset do
  @moduledoc """
  Drops the ScyllaDB keyspace (and all its data) and re-runs migrations.

  This task:
  1. Drops the existing keyspace with `DROP KEYSPACE IF EXISTS`
  2. Recreates the keyspace
  3. Runs the migration task to rebuild the schema

  ## Usage

      # Reset the auto-detected repo
      mix ash_scylla.reset

      # Reset a specific repo
      mix ash_scylla.reset --repo MyApp.Repo

  ## Options

    - `--repo` - The repo module to use (defaults to auto-detected repo)
    - `--keyspace` - Override the keyspace name
    - `--nodes` - Override the ScyllaDB nodes (comma-separated)
    - `--dry-run` - Print what would be done without executing
    - `--quiet` - Suppress output
  """

  use Mix.Task

  @shortdoc "Drops the keyspace and re-runs migrations"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          repo: :string,
          keyspace: :string,
          nodes: :string,
          dry_run: :boolean,
          quiet: :boolean
        ]
      )

    opts = AshScylla.MixHelpers.maybe_atomize(opts, :repo)

    repo = find_repo(opts)
    keyspace = Keyword.get(opts, :keyspace) || repo.keyspace()

    if Keyword.get(opts, :dry_run, false) do
      Mix.shell().info("=== DRY RUN ===")
      Mix.shell().info("Would drop keyspace #{inspect(keyspace)} and re-run migrations.")
      :ok
    else
      # DROP KEYSPACE in ScyllaDB is asynchronous: metadata disappears from
      # system_schema immediately, but on-disk data can linger. A subsequent
      # CREATE KEYSPACE can silently inherit the old data, making reset a
      # no-op. We handle this by dropping and recreating the keyspace, then
      # *verifying* that the old tables are gone. If they survived (race),
      # we retry the entire cycle.
      release_keyspace_sessions(repo)
      drop_and_recreate_keyspace(repo, keyspace, opts)
      ensure_repo_connected(repo)
      run_migrate(opts)
    end
  end

  # Resolves the ScyllaDB nodes to use for temp connections.
  # Prefers the running connection's state (which may have been set dynamically,
  # e.g. by test setup or env vars) over Application env config.
  defp resolve_nodes(repo) do
    case AshScylla.Connection.get_conn(repo) do
      %AshScylla.Connection{nodes: nodes} when nodes != [] -> nodes
      _ -> repo.nodes()
    end
  end

  # Retries the drop+create cycle up to 10 times until the old tables are
  # actually gone from the fresh keyspace.
  defp drop_and_recreate_keyspace(repo, keyspace, opts, retries \\ 10) do
    drop_keyspace(repo, keyspace)
    wait_for_keyspace_gone(repo, keyspace)
    create_keyspace(repo, opts)
    wait_for_keyspace_ready(repo, keyspace)

    # NEW: poll for a settling window to confirm the keyspace is truly empty.
    # The ScyllaDB async-drop race can cause old tables to reappear seconds
    # after CREATE KEYSPACE appears to succeed.
    if verify_keyspace_empty(repo, keyspace) do
      :ok
    else
      if retries > 0 do
        Mix.shell().info(
          "Old data still present in keyspace, retrying drop+create (#{retries} retries left)..."
        )

        drop_and_recreate_keyspace(repo, keyspace, opts, retries - 1)
      else
        Mix.raise("""
        Failed to reset keyspace #{inspect(keyspace)}: old data persists after \
        #{10} drop+create attempts. This is a ScyllaDB async-drop race condition.
        """)
      end
    end
  end

  # Polls the keyspace for 5 seconds, checking every 500ms, to confirm that
  # no tables reappear.  Returns true if the keyspace stays empty throughout
  # the window, false if any table is found.
  defp verify_keyspace_empty(repo, keyspace, polls_remaining \\ 10) do
    # Wait 500ms before each check to give the async coordinator time to
    # settle the race.
    Process.sleep(500)

    if old_tables_survived?(repo, keyspace) do
      false
    else
      if polls_remaining > 0 do
        verify_keyspace_empty(repo, keyspace, polls_remaining - 1)
      else
        true
      end
    end
  end

  # Checks whether tables from the old keyspace survived the create.
  defp old_tables_survived?(repo, keyspace) do
    temp_name = :"#{inspect(repo)}_verify_#{:erlang.unique_integer([:positive])}"
    nodes = resolve_nodes(repo)

    case AshScylla.Connection.start_link(name: temp_name, nodes: nodes) do
      {:ok, _} ->
        result =
          AshScylla.Connection.query(
            temp_name,
            "SELECT table_name FROM system_schema.tables WHERE keyspace_name = ?",
            [{"text", keyspace}],
            consistency: :one
          )

        AshScylla.Connection.stop(temp_name)

        case result do
          {:ok, %Xandra.Page{content: rows}} when is_list(rows) -> rows != []
          {:ok, %Xandra.Page{content: nil}} -> false
          _ -> true
        end

      {:error, _} ->
        true
    end
  end

  # Releases the repo connection's active `USE <keyspace>` session (and any
  # other keyspace-bound session we control) so the subsequent DROP KEYSPACE
  # is not deferred/blocked. We release the session in place rather than
  # stopping the connection: a full GenServer stop is asynchronous and the
  # underlying Xandra socket may linger, which would still block the drop.
  defp release_keyspace_sessions(repo) do
    case AshScylla.Connection.get_conn(repo) do
      nil ->
        :ok

      %AshScylla.Connection{} ->
        case AshScylla.Connection.release_session(repo) do
          :ok -> :ok
          {:error, _} -> :ok
        end
    end
  rescue
    _ ->
      :ok
  end

  # Re-establishes the repo's named connection after the keyspace has been
  # recreated, so subsequent operations (e.g. migrations) can use it. If the
  # connection is missing or dead, start a fresh one; if it cannot be started,
  # raise rather than silently proceeding (a dead repo connection would make
  # migrations a no-op and leave the keyspace empty).
  defp ensure_repo_connected(repo) do
    case AshScylla.Connection.get_conn(repo) do
      %AshScylla.Connection{} ->
        # Session was released but the connection is alive; re-bind it to the
        # (recreated) keyspace.
        AshScylla.Connection.reconnect_keyspace(repo)
        :ok

      nil ->
        keyspace = repo.keyspace()
        nodes = resolve_nodes(repo)

        case AshScylla.Connection.start_link(name: repo, nodes: nodes, keyspace: keyspace) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Mix.raise("Failed to reconnect repo after reset: #{inspect(reason)}")
        end
    end
  rescue
    _ ->
      :ok
  end

  # ── Keyspace Drop + Wait ──────────────────────────────────────────────────

  defp drop_keyspace(repo, keyspace) do
    Mix.shell().info("Dropping keyspace #{inspect(keyspace)}...")

    # Use a temporary, keyspace-less connection for the DROP. ScyllaDB defers
    # (or blocks) DROP KEYSPACE while another connection holds an active
    # `USE <keyspace>` session, so dropping via the repo's keyspace-bound
    # connection would never complete. A keyspace-less temp connection avoids
    # that and lets the drop actually take effect.
    case drop_keyspace_via_temp(repo, keyspace) do
      {:ok, _} ->
        Mix.shell().info("Keyspace dropped successfully.")

      {:error, error} ->
        # If the keyspace doesn't exist, that's fine — the next step will
        # create it.
        if String.contains?(inspect(error), "not exist") do
          Mix.shell().info("Keyspace #{inspect(keyspace)} does not exist, nothing to drop.")
        else
          Mix.shell().error("Failed to drop keyspace: #{inspect(error)}")
          Mix.raise("Keyspace drop failed")
        end
    end
  end

  defp drop_keyspace_via_temp(repo, keyspace) do
    temp_name = :"#{inspect(repo)}_drop_temp_#{:erlang.unique_integer([:positive])}"
    nodes = resolve_nodes(repo)

    with {:ok, _} <- AshScylla.Connection.start_link(name: temp_name, nodes: nodes) do
      query = "DROP KEYSPACE IF EXISTS #{AshScylla.Identifier.quote_name(keyspace)}"
      result = AshScylla.Connection.query(temp_name, query, [], consistency: :quorum)
      AshScylla.Connection.stop(temp_name)
      result
    end
  end

  # ScyllaDB's DROP KEYSPACE is asynchronous: the keyspace is removed from
  # `system_schema.keyspaces` immediately, but its tables linger in
  # `system_schema.tables` during the "dropping" state. A `CREATE KEYSPACE`
  # issued while the old keyspace is still dropping would either fail (plain
  # CREATE) or be a silent no-op (IF NOT EXISTS), leaving the old data behind.
  # Wait until BOTH the keyspace entry and all of its tables are gone before
  # recreating it.
  defp wait_for_keyspace_gone(repo, keyspace, retries \\ 120) do
    cond do
      tables_exist?(repo, keyspace) ->
        if retries > 0 do
          Process.sleep(500)
          wait_for_keyspace_gone(repo, keyspace, retries - 1)
        else
          Mix.shell().error(
            "Timed out waiting for tables of keyspace #{inspect(keyspace)} to finish dropping."
          )
        end

      keyspace_exists?(repo, keyspace) ->
        if retries > 0 do
          Process.sleep(500)
          wait_for_keyspace_gone(repo, keyspace, retries - 1)
        else
          Mix.shell().error(
            "Timed out waiting for keyspace #{inspect(keyspace)} to finish dropping."
          )
        end

      true ->
        # Both gone: give the cluster a brief moment to settle before recreating.
        Process.sleep(250)
        :ok
    end
  end

  # After CREATE KEYSPACE, wait until the keyspace is visible in
  # system_schema before proceeding.
  defp wait_for_keyspace_ready(repo, keyspace, retries \\ 30) do
    if !keyspace_exists?(repo, keyspace) do
      if retries > 0 do
        Process.sleep(500)
        wait_for_keyspace_ready(repo, keyspace, retries - 1)
      else
        Mix.raise("Timed out waiting for keyspace #{inspect(keyspace)} to become available.")
      end
    end
  end

  defp keyspace_exists?(repo, keyspace) do
    temp_name = :"#{inspect(repo)}_wait_temp_#{:erlang.unique_integer([:positive])}"
    nodes = resolve_nodes(repo)

    case AshScylla.Connection.start_link(name: temp_name, nodes: nodes) do
      {:ok, _} ->
        result =
          AshScylla.Connection.query(
            temp_name,
            "SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name = ?",
            [{"text", keyspace}],
            consistency: :one
          )

        AshScylla.Connection.stop(temp_name)

        case result do
          {:ok, %Xandra.Page{content: rows}} -> length(rows || []) == 1
          _ -> true
        end

      {:error, _} ->
        true
    end
  end

  defp tables_exist?(repo, keyspace) do
    temp_name = :"#{inspect(repo)}_wait_tbl_#{:erlang.unique_integer([:positive])}"
    nodes = resolve_nodes(repo)

    case AshScylla.Connection.start_link(name: temp_name, nodes: nodes) do
      {:ok, _} ->
        result =
          AshScylla.Connection.query(
            temp_name,
            "SELECT table_name FROM system_schema.tables WHERE keyspace_name = ?",
            [{"text", keyspace}],
            consistency: :one
          )

        AshScylla.Connection.stop(temp_name)

        case result do
          {:ok, %Xandra.Page{content: rows}} -> (rows || []) != []
          _ -> true
        end

      {:error, _} ->
        true
    end
  end

  # ── Keyspace Create ───────────────────────────────────────────────────────

  defp create_keyspace(repo, opts) do
    keyspace = Keyword.get(opts, :keyspace) || repo.keyspace()
    replication = repo.build_replication_clause(opts)
    quoted_keyspace = AshScylla.Identifier.quote_name(keyspace)

    query = """
    CREATE KEYSPACE #{quoted_keyspace}
    WITH REPLICATION = #{replication}
    """

    Mix.shell().info("Creating keyspace #{inspect(keyspace)}...")
    create_keyspace_with_retry(repo, keyspace, query)
  end

  defp create_keyspace_with_retry(repo, keyspace, query, retries \\ 30) do
    temp_name = :"#{inspect(repo)}_create_temp_#{:erlang.unique_integer([:positive])}"
    nodes = resolve_nodes(repo)

    case AshScylla.Connection.start_link(name: temp_name, nodes: nodes) do
      {:ok, _} ->
        result = AshScylla.Connection.query(temp_name, query, [], consistency: :quorum)
        AshScylla.Connection.stop(temp_name)

        case result do
          {:ok, _} ->
            Mix.shell().info("Keyspace created successfully.")
            :ok

          {:error, reason} ->
            # While the previous keyspace is still in its "dropping" state the
            # CREATE may fail transiently. Back off and retry only for errors
            # that indicate the drop is still in flight. A definitive "keyspace
            # already exists" error must NOT be retried — it means the drop
            # never happened and retrying would mask the real failure.
            if retries > 0 and dropping?(reason) do
              Process.sleep(500)
              create_keyspace_with_retry(repo, keyspace, query, retries - 1)
            else
              Mix.shell().error("Failed to create keyspace: #{inspect(reason)}")
              Mix.raise("Keyspace creation failed")
            end
        end

      {:error, reason} ->
        Mix.shell().error("Failed to create keyspace: #{inspect(reason)}")
        Mix.raise("Keyspace creation failed")
    end
  end

  defp dropping?(reason) do
    message = inspect(reason)

    String.contains?(message, "still being dropped") or
      String.contains?(message, "is being dropped") or
      String.contains?(message, "Keyspace or table being dropped") or
      String.contains?(message, "Configuration change is in progress")
  end

  # ── Repo Discovery ───────────────────────────────────────────────────────

  defp find_repo(opts) do
    case Keyword.get(opts, :repo) do
      nil -> AshScylla.MixHelpers.find_default_repo()
      repo -> validate_repo!(repo)
    end
  end

  defp validate_repo!(repo) do
    case Code.ensure_loaded(repo) do
      {:module, _} ->
        validate_repo_functions(repo)

      {:error, _} ->
        Mix.Task.run("compile", [])
        ensure_repo_available(repo)
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

      Mix.raise("""
      Repo module #{inspect(repo)} is missing required functions: #{Enum.join(missing, ", ")}.

      Make sure your repo uses AshScylla.Repo:

          defmodule #{inspect(repo)} do
            use AshScylla.Repo,
              otp_app: :#{app}
          end
      """)
    end
  end

  defp ensure_repo_available(repo) do
    case Code.ensure_compiled(repo) do
      {:module, _} -> repo
      {:error, _} -> :ok
    end

    add_child_app_paths()

    case Code.ensure_compiled(repo) do
      {:module, _} ->
        repo

      {:error, :nofile} ->
        Mix.raise("Repo module #{inspect(repo)} does not exist.")

      {:error, reason} ->
        Mix.raise("Repo module #{inspect(repo)} could not be loaded: #{inspect(reason)}.")
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
    |> Enum.each(fn ebin -> :code.add_pathsa([ebin]) end)
  end

  defp run_migrate(opts) do
    migrate_args =
      opts
      |> Enum.flat_map(fn
        {:repo, repo} -> ["--repo", inspect(repo)]
        {:keyspace, ks} -> ["--keyspace", ks]
        {:nodes, nodes} -> ["--nodes", nodes]
        {:quiet, true} -> ["--quiet"]
        _ -> []
      end)

    Mix.Task.run("ash_scylla.migrate", migrate_args)
  end
end
