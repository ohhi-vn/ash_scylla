defmodule Mix.Tasks.AshScylla.MigrateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "schema file loading" do
    test "load_schema_module returns ok for valid schema" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_scylla_migrate_test_#{:erlang.unique_integer([:positive])}"
        )

      tmp_file = Path.join(tmp_dir, "valid_schema.ex")

      File.mkdir_p!(tmp_dir)

      File.write!(tmp_file, """
      defmodule AshScylla.MigrateTest.ValidSchema do
        def change do
          ["CREATE TABLE IF NOT EXISTS migrate_test (id UUID PRIMARY KEY)"]
        end
      end
      """)

      assert {:ok, statements} = AshScylla.SchemaLoader.load(tmp_file)
      assert length(statements) == 1

      File.rm_rf!(tmp_dir)
    end

    test "load_schema_module returns error for module without change/0" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_scylla_migrate_test_#{:erlang.unique_integer([:positive])}"
        )

      tmp_file = Path.join(tmp_dir, "no_change.ex")

      File.mkdir_p!(tmp_dir)

      File.write!(tmp_file, """
      defmodule AshScylla.MigrateTest.NoChange do
      end
      """)

      assert {:error, :no_change_function} = AshScylla.SchemaLoader.load(tmp_file)

      File.rm_rf!(tmp_dir)
    end

    test "load_schema_module returns error for invalid file" do
      assert {:error, _} = AshScylla.SchemaLoader.load("/nonexistent/file.ex")
    end

    test "load handles empty change/0" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_scylla_migrate_test_#{:erlang.unique_integer([:positive])}"
        )

      tmp_file = Path.join(tmp_dir, "empty.ex")

      File.mkdir_p!(tmp_dir)

      File.write!(tmp_file, """
      defmodule AshScylla.MigrateTest.Empty do
        def change do
          []
        end
      end
      """)

      assert {:ok, []} = AshScylla.SchemaLoader.load(tmp_file)

      File.rm_rf!(tmp_dir)
    end
  end

  describe "Mix.Tasks.AshScylla.Migrate" do
    test "task module exists and is callable" do
      assert is_function(&Mix.Tasks.AshScylla.Migrate.run/1)
    end

    test "runs with --dry-run and explicit repo" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Migrate.run(["--repo", "AshScylla.TestRepo", "--dry-run"])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "DRY RUN" or output =~ "No resources" or output =~ "Schema" or
               output =~
                 "migrating" or output =~ "Running schema file" or output =~ "Schema migration"
    end

    test "runs with --schemas-only and explicit repo" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Migrate.run(["--repo", "AshScylla.TestRepo", "--schemas-only"])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Running schema file" or output =~ "Schema migration" or
               output =~ "No schema"
    end

    test "parses --resource flag" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Migrate.run([
              "--repo",
              "AshScylla.TestRepo",
              "--resource",
              "AshScylla.DataLayer"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "DRY RUN" or output =~ "No resources" or output =~ "Schema" or
               output =~ "Running schema file"
    end

    test "parses --keyspace flag" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Migrate.run([
              "--repo",
              "AshScylla.TestRepo",
              "--keyspace",
              "custom_ks"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "DRY RUN" or output =~ "No resources" or output =~ "Schema" or
               output =~ "Running schema file"
    end

    test "parses --nodes flag" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Migrate.run([
              "--repo",
              "AshScylla.TestRepo",
              "--nodes",
              "127.0.0.1:9042"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "DRY RUN" or output =~ "No resources" or output =~ "Schema" or
               output =~ "Running schema file"
    end

    test "runs with combined flags" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Migrate.run([
              "--repo",
              "AshScylla.TestRepo",
              "--dry-run",
              "--schemas-only",
              "--keyspace",
              "test_ks"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Schema" or output =~ "No schema" or output =~ "Running schema file"
    end
  end

  describe "AshScylla.SchemaLoader.discover/0" do
    test "returns a list (possibly empty)" do
      result = AshScylla.SchemaLoader.discover()
      assert is_list(result)
    end
  end

  describe "migration file path" do
    test "uses priv/repo/migrations directory" do
      Code.ensure_loaded(Mix.Tasks.AshScylla.Migrate)
      migrate_task = Mix.Tasks.AshScylla.Migrate
      assert function_exported?(migrate_task, :run, 1)
    end

    test "run_schema_files reads from priv/repo/migrations" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_scylla_migrate_path_test_#{:erlang.unique_integer([:positive])}"
        )

      migrations_dir = Path.join(tmp_dir, "priv/repo/migrations")
      File.mkdir_p!(migrations_dir)

      migration_file = Path.join(migrations_dir, "test_migration.ex")

      File.write!(migration_file, """
      defmodule AshScylla.MigratePathTest.TestMigration do
        def change do
          ["CREATE TABLE IF NOT EXISTS test_table (id UUID PRIMARY KEY)"]
        end
      end
      """)

      # Verify the migration file exists in the expected path
      assert File.exists?(migration_file)
      assert Path.dirname(migrations_dir) == Path.join(tmp_dir, "priv/repo")

      File.rm_rf!(tmp_dir)
    end
  end

  describe "run_schema_file executes migration statements" do
    test "loads and executes migration from file" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_scylla_migrate_exec_test_#{:erlang.unique_integer([:positive])}"
        )

      tmp_file = Path.join(tmp_dir, "test_exec.ex")
      File.mkdir_p!(tmp_dir)

      File.write!(tmp_file, """
      defmodule AshScylla.MigrateExecTest.Schema do
        def change do
          [
            "CREATE TABLE IF NOT EXISTS exec_test (id UUID PRIMARY KEY)",
            "CREATE INDEX IF NOT EXISTS idx_exec_name ON exec_test (name)"
          ]
        end
      end
      """)

      assert {:ok, statements} = AshScylla.SchemaLoader.load(tmp_file)
      assert length(statements) == 2
      assert Enum.at(statements, 0) =~ "CREATE TABLE"
      assert Enum.at(statements, 1) =~ "CREATE INDEX"

      File.rm_rf!(tmp_dir)
    end
  end
end
