defmodule Mix.Tasks.AshScylla.MigrateTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defmodule MigrateMockRepo do
    def config do
      [nodes: ["127.0.0.1:1"], keyspace: "migrate_ks", connect_timeout: 100]
    end

    def nodes, do: ["127.0.0.1:1"]
    def keyspace, do: "migrate_ks"
    def create_keyspace(keyspace), do: {:ok, keyspace}
  end

  defmodule FailingKeyspaceRepo do
    def config do
      [nodes: ["127.0.0.1:1"], keyspace: "migrate_ks", connect_timeout: 100]
    end

    def nodes, do: ["127.0.0.1:1"]
    def keyspace, do: "migrate_ks"
    def create_keyspace(_keyspace), do: {:error, :nope}
  end

  defmodule RepoWithoutFunctions do
  end

  describe "Mix.Tasks.AshScylla.Migrate" do
    test "task module exists" do
      assert Code.ensure_loaded?(Mix.Tasks.AshScylla.Migrate)
    end

    test "run/1 is exported" do
      assert function_exported?(Code.ensure_loaded!(Mix.Tasks.AshScylla.Migrate), :run, 1)
    end

    test "raises Mix.Error when repo is missing required functions" do
      assert_raise Mix.Error, ~r/missing required functions/, fn ->
        capture_io(fn ->
          Mix.Tasks.AshScylla.Migrate.run([
            "--repo",
            "Mix.Tasks.AshScylla.MigrateTaskTest.RepoWithoutFunctions"
          ])
        end)
      end
    end

    test "raises Mix.Error when repo does not exist" do
      assert_raise Mix.Error, ~r/does not exist/, fn ->
        capture_io(fn ->
          Mix.Tasks.AshScylla.Migrate.run(["--repo", "NoSuchRepoModuleForMigrateTest"])
        end)
      end
    end

    test "raises Mix.Error when keyspace creation fails" do
      assert_raise Mix.Error, ~r/Keyspace creation failed/, fn ->
        capture_io(fn ->
          Mix.Tasks.AshScylla.Migrate.run([
            "--repo",
            "Mix.Tasks.AshScylla.MigrateTaskTest.FailingKeyspaceRepo",
            "--create-keyspace",
            "--migrations-only",
            "--schemas-only"
          ])
        end)
      end
    end

    test "creates keyspace and skips both schema phases" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Migrate.run([
            "--repo",
            "Mix.Tasks.AshScylla.MigrateTaskTest.MigrateMockRepo",
            "--create-keyspace",
            "--migrations-only",
            "--schemas-only"
          ])
        end)

      assert output =~ "Creating keyspace"
      assert output =~ "Keyspace created successfully."
    end

    test "dry run reports resources that would auto-migrate" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Migrate.run([
            "--repo",
            "Mix.Tasks.AshScylla.MigrateTaskTest.MigrateMockRepo",
            "--dry-run",
            "--migrations-only"
          ])
        end)

      assert output =~ "DRY RUN"
      assert output =~ "would auto-migrate"
    end

    test "filters resources by --resource flag" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Migrate.run([
            "--repo",
            "Mix.Tasks.AshScylla.MigrateTaskTest.MigrateMockRepo",
            "--dry-run",
            "--migrations-only",
            "--resource",
            "AshScylla.TestResource"
          ])
        end)

      assert output =~ "AshScylla.TestResource: would auto-migrate"
      refute output =~ "AshScylla.TestResourceWithIndexes: would auto-migrate"
    end

    test "raises Mix.Error when a migration file fails" do
      invalid = """
      defmodule Mix.Tasks.AshScylla.MigrateTaskTest.NoChangeFile do
      end
      """

      with_migration_files([{"20260101000000_unit_b.exs", invalid}], fn _ ->
        assert_raise Mix.Error, ~r/1 migration\(s\) failed/, fn ->
          capture_io(fn ->
            Mix.Tasks.AshScylla.Migrate.run([
              "--repo",
              "Mix.Tasks.AshScylla.MigrateTaskTest.MigrateMockRepo",
              "--dry-run"
            ])
          end)
        end
      end)
    end

    test "runs migration files and reports success" do
      valid = """
      defmodule Mix.Tasks.AshScylla.MigrateTaskTest.ValidRunFile do
        def change do
          ["CREATE TABLE IF NOT EXISTS unit_test_run (id UUID PRIMARY KEY)"]
        end
      end
      """

      with_migration_files([{"20260102000000_unit_ok.exs", valid}], fn _ ->
        output =
          capture_io(fn ->
            Mix.Tasks.AshScylla.Migrate.run([
              "--repo",
              "Mix.Tasks.AshScylla.MigrateTaskTest.MigrateMockRepo",
              "--dry-run"
            ])
          end)

        assert output =~ "Migration: 20260102000000_unit_ok.exs"
        assert output =~ "CREATE TABLE IF NOT EXISTS unit_test_run"
        assert output =~ "Migration complete"
      end)
    end

    test "honors --to version filter" do
      v1 = """
      defmodule Mix.Tasks.AshScylla.MigrateTaskTest.ToV1 do
        def change do
          ["CREATE TABLE IF NOT EXISTS to_v1 (id UUID PRIMARY KEY)"]
        end
      end
      """

      v2 = """
      defmodule Mix.Tasks.AshScylla.MigrateTaskTest.ToV2 do
        def change do
          ["CREATE TABLE IF NOT EXISTS to_v2 (id UUID PRIMARY KEY)"]
        end
      end
      """

      with_migration_files(
        [{"20260101000000_to_one.exs", v1}, {"20260201000000_to_two.exs", v2}],
        fn _ ->
          output =
            capture_io(fn ->
              Mix.Tasks.AshScylla.Migrate.run([
                "--repo",
                "Mix.Tasks.AshScylla.MigrateTaskTest.MigrateMockRepo",
                "--dry-run",
                "--to",
                "20260101000000"
              ])
            end)

          assert output =~ "to_one.exs"
          refute output =~ "to_two.exs"
          assert output =~ "1 migration(s) skipped by version filter"
        end
      )
    end

    test "honors --step count filter" do
      v1 = """
      defmodule Mix.Tasks.AshScylla.MigrateTaskTest.StepV1 do
        def change do
          ["CREATE TABLE IF NOT EXISTS step_v1 (id UUID PRIMARY KEY)"]
        end
      end
      """

      v2 = """
      defmodule Mix.Tasks.AshScylla.MigrateTaskTest.StepV2 do
        def change do
          ["CREATE TABLE IF NOT EXISTS step_v2 (id UUID PRIMARY KEY)"]
        end
      end
      """

      with_migration_files(
        [{"20260101000000_step_one.exs", v1}, {"20260201000000_step_two.exs", v2}],
        fn _ ->
          output =
            capture_io(fn ->
              Mix.Tasks.AshScylla.Migrate.run([
                "--repo",
                "Mix.Tasks.AshScylla.MigrateTaskTest.MigrateMockRepo",
                "--dry-run",
                "--step",
                "1"
              ])
            end)

          assert output =~ "step_one.exs"
          refute output =~ "step_two.exs"
        end
      )
    end
  end

  defp with_migration_files(files, fun) do
    dir = Path.join(File.cwd!(), "priv/repo/migrations")
    paths = Enum.map(files, fn {name, _} -> Path.join(dir, name) end)

    Enum.each(Enum.zip(files, paths), fn {{_, content}, path} ->
      File.write!(path, content)
    end)

    try do
      fun.(dir)
    after
      Enum.each(paths, &File.rm/1)
    end
  end
end
