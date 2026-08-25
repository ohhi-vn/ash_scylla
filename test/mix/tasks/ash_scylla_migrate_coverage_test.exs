defmodule Mix.Tasks.AshScylla.MigrateCoverageTest do
  @moduledoc """
  Line-coverage tests for Mix.Tasks.AshScylla.Migrate covering argument
  handling, repo discovery/validation failures, version filtering, dry-run
  reporting, schema-file loading errors, and the auto-schema flow against an
  unreachable node (127.0.0.1:59999) so no ScyllaDB is required.

  Runs with async: false because tests flip the VM-wide working directory,
  mutate Application env for the repo config, and drive global Mix state.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defmodule QbmMigrateRepo do
    @moduledoc false
    use AshScylla.Repo, otp_app: :ash_scylla
  end

  @qbm_repo "Mix.Tasks.AshScylla.MigrateCoverageTest.QbmMigrateRepo"

  setup do
    Application.put_env(:ash_scylla, QbmMigrateRepo,
      nodes: ["127.0.0.1:59999"],
      keyspace: "qbm_migrate_task_ks",
      connect_timeout: 100
    )

    on_exit(fn ->
      Application.delete_env(:ash_scylla, QbmMigrateRepo)
      AshScylla.Connection.stop(QbmMigrateRepo)
    end)

    :ok
  end

  describe "repo discovery and validation" do
    test "defaults to the repo discovered from configured domains" do
      root = new_root()

      {out, _err, result} =
        with_root(root, fn -> run_task(["--dry-run", "--schemas-only"]) end)

      assert {:ok, _} = result
      assert out =~ "Migration complete:"
    end

    test "raises a helpful error when the repo module is not a repo" do
      {_out, _err, result} = run_task(["--repo", "AshScylla.Identifier", "--migrations-only"])

      assert {:error, message} = result
      assert message =~ "missing required functions"
      assert message =~ "nodes/0"
      assert message =~ "keyspace/0"
    end

    test "raises when the repo module does not exist" do
      {out, _err, result} =
        run_task([
          "--repo",
          "Mix.Tasks.AshScylla.MigrateCoverage.NoSuchRepo",
          "--migrations-only"
        ])

      assert {:error, message} = result
      assert message =~ "does not exist"
      assert out =~ "Searched paths:"
      assert out =~ "Module path:"
    end
  end

  describe "keyspace creation" do
    test "reports and raises when keyspace creation fails" do
      {_out, _err, result} =
        run_task(["--repo", @qbm_repo, "--create-keyspace", "--migrations-only"])

      assert {:error, message} = result
      assert message =~ "Keyspace creation failed"
    end
  end

  describe "schema file discovery, version parsing, and filtering" do
    test "dry run prints statements, skips unparseable filenames, and reports load failures" do
      root = new_root()

      write_file(
        root,
        "20260101000001_create_users.exs",
        schema_source(11, [
          "CREATE TABLE IF NOT EXISTS qbm_users_x (id UUID PRIMARY KEY)",
          "CREATE INDEX IF NOT EXISTS idx_qbm_users_x_email ON qbm_users_x (email)"
        ])
      )

      write_file(root, "20260101000002_empty.exs", schema_source(12, []))

      write_file(
        root,
        "schema20260101000003.exs",
        schema_source(13, ["SELECT now() FROM system.local"])
      )

      write_file(root, "20260101000004_no_change.exs", """
      defmodule Mix.Tasks.AshScylla.MigrateCoverage.S14 do
      end
      """)

      write_file(root, "20260101000005_broken.exs", """
      raise "qbm intentional compile boom"
      """)

      write_file(root, "20260101000006_empty_file.exs", "")

      write_file(root, "20260101000007_two_modules.exs", """
      defmodule Mix.Tasks.AshScylla.MigrateCoverage.S17 do
        use AshScylla.Schema

        def change, do: ["SELECT now() FROM system.local"]
      end

      defmodule Mix.Tasks.AshScylla.MigrateCoverage.S18 do
        use AshScylla.Schema

        def change, do: ["SELECT now() FROM system.local"]
      end
      """)

      write_file(root, "schema_notanumber.exs", "schema_notanumber_marker_should_not_appear")
      write_file(root, "notes_readme.exs", "notes_readme_marker_should_not_appear")

      {out, err, result} =
        with_root(root, fn -> run_task(["--repo", "AshScylla.TestRepo", "--dry-run"]) end)

      assert out =~ "=== DRY RUN ==="
      assert out =~ "Running 7 schema file(s)"
      assert out =~ "CREATE TABLE IF NOT EXISTS qbm_users_x"
      assert out =~ "(no statements)"
      refute out =~ "notes_readme_marker_should_not_appear"
      refute out =~ "schema_notanumber_marker_should_not_appear"

      assert err =~ "FAILED to load"

      assert {:error, message} = result
      assert message =~ "4 migration(s) failed"
    end

    test "--to skips later migrations" do
      root = new_root()
      write_numbered_files(root, [20_260_101_000_001, 20_260_101_000_002, 20_260_101_000_003])

      {out, _err, result} =
        with_root(root, fn ->
          run_task(["--repo", "AshScylla.TestRepo", "--dry-run", "--to", "20260101000002"])
        end)

      assert {:ok, _} = result
      assert out =~ "skipped by version filter"
      assert out =~ "Migration complete:"
    end

    test "--step limits how many pending migrations run" do
      root = new_root()
      write_numbered_files(root, [20_260_101_000_001, 20_260_101_000_002, 20_260_101_000_003])

      {_out, _err, result} =
        with_root(root, fn ->
          run_task(["--repo", "AshScylla.TestRepo", "--dry-run", "--step", "1"])
        end)

      assert {:ok, _} = result
    end

    test "--to combined with --step applies both filters" do
      root = new_root()

      write_numbered_files(root, [
        20_260_101_000_001,
        20_260_101_000_002,
        20_260_101_000_003,
        20_260_101_000_004
      ])

      {out, _err, result} =
        with_root(root, fn ->
          run_task([
            "--repo",
            "AshScylla.TestRepo",
            "--dry-run",
            "--to",
            "20260101000003",
            "--step",
            "1"
          ])
        end)

      assert {:ok, _} = result
      assert out =~ "3 migration(s) skipped by version filter"
    end

    test "missing migrations directory is reported gracefully" do
      root = new_bare_root()

      {out, _err, result} =
        with_root(root, fn -> run_task(["--repo", "AshScylla.TestRepo", "--dry-run"]) end)

      assert {:ok, _} = result
      assert out =~ "No schema files found"
      assert out =~ "would auto-migrate"
    end
  end

  describe "non-dry-run execution against unreachable nodes" do
    test "schema file execution failure is reported and the task raises in the summary" do
      root = new_root()

      write_file(
        root,
        "20260101000009_create.exs",
        schema_source(19, ["CREATE TABLE qbm_y (id UUID PRIMARY KEY)"])
      )

      {out, err, result} = with_root(root, fn -> run_task(["--repo", @qbm_repo]) end)

      assert {:error, message} = result
      assert message =~ "1 migration(s) failed"
      assert out =~ "20260101000009_create.exs"
      assert err =~ "FAILED:"
    end

    test "auto-schema migration reports no changes when the live schema cannot be read" do
      root = new_root()

      {out, _err, result} =
        with_root(root, fn ->
          run_task(["--repo", @qbm_repo, "--resource", "AshScylla.TestResource"])
        end)

      assert {:ok, _} = result
      assert out =~ "Auto-migrating AshScylla.TestResource"
      assert out =~ "no changes needed"
    end

    test "auto-schema reuses an already-running repo connection" do
      root = new_root()

      {:ok, _} =
        AshScylla.Connection.start_link(
          name: QbmMigrateRepo,
          nodes: ["127.0.0.1:59999"],
          keyspace: "qbm_migrate_task_ks"
        )

      {out, _err, result} =
        with_root(root, fn ->
          run_task(["--repo", @qbm_repo, "--resource", "AshScylla.TestResource"])
        end)

      assert {:ok, _} = result
      assert out =~ "no changes needed"
      refute Process.whereis(QbmMigrateRepo)
    end

    test "auto-schema dry run only reports what would be migrated" do
      root = new_root()

      {out, _err, result} =
        with_root(root, fn ->
          run_task([
            "--repo",
            "AshScylla.TestRepo",
            "--dry-run",
            "--resource",
            "AshScylla.TestResource"
          ])
        end)

      assert {:ok, _} = result
      assert out =~ "AshScylla.TestResource: would auto-migrate"
      refute out =~ "no changes needed"
    end

    test "--resource filter matching nothing reports no resources" do
      root = new_root()

      {out, _err, result} =
        with_root(root, fn ->
          run_task([
            "--repo",
            "AshScylla.TestRepo",
            "--dry-run",
            "--resource",
            "NoSuch.QbmResource"
          ])
        end)

      assert {:ok, _} = result
      assert out =~ "No resources found to migrate."
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp run_task(args) do
    parent = self()

    out =
      capture_io(fn ->
        err =
          capture_io(:stderr, fn ->
            result =
              try do
                {:ok, Mix.Tasks.AshScylla.Migrate.run(args)}
              rescue
                e in Mix.Error -> {:error, Exception.message(e)}
              end

            send(parent, {:qbm_result, result})
          end)

        send(parent, {:qbm_err, err})
      end)

    assert_receive({:qbm_result, result}, 10_000)
    assert_receive({:qbm_err, err}, 10_000)
    {out, err, result}
  end

  defp with_root(root, fun) do
    original = File.cwd!()
    File.cd!(root)

    try do
      fun.()
    after
      File.cd!(original)
    end
  end

  defp new_root do
    root =
      Path.join([File.cwd!(), "tmp", "qbm_migrate_#{System.unique_integer([:positive])}"])

    File.mkdir_p!(Path.join(root, "priv/repo/migrations"))
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp new_bare_root do
    root =
      Path.join([File.cwd!(), "tmp", "qbm_migrate_#{System.unique_integer([:positive])}"])

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp write_file(root, name, contents) do
    root
    |> Path.join("priv/repo/migrations")
    |> Path.join(name)
    |> File.write!(contents)
  end

  defp write_numbered_files(root, versions) do
    Enum.each(versions, fn version ->
      uid = "#{version}_#{System.unique_integer([:positive])}"

      write_file(
        root,
        "#{version}_migration.exs",
        schema_source(uid, ["SELECT now() FROM system.local"])
      )
    end)
  end

  defp schema_source(uid, statements) do
    """
    defmodule Mix.Tasks.AshScylla.MigrateCoverage.S#{uid} do
      use AshScylla.Schema

      def change do
        #{inspect(statements)}
      end
    end
    """
  end
end
