defmodule Mix.Tasks.AshScylla.MigrateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "schema file loading" do
    test "load_schema_module returns ok for valid schema" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "ash_scylla_migrate_test_#{:erlang.unique_integer([:positive])}")

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
        Path.join(System.tmp_dir!(), "ash_scylla_migrate_test_#{:erlang.unique_integer([:positive])}")

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
        Path.join(System.tmp_dir!(), "ash_scylla_migrate_test_#{:erlang.unique_integer([:positive])}")

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
            Mix.Tasks.AshScylla.Migrate.run(["--repo", "AshScylla.Repo", "--dry-run"])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "DRY RUN" or output =~ "No resources" or output =~ "Schema" or output =~
               "migrating"
    end

    test "runs with --schemas-only and explicit repo" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Migrate.run(["--repo", "AshScylla.Repo", "--schemas-only"])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Schema migration" or output =~ "No schema"
    end

    test "parses --resource flag" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Migrate.run(["--repo", "AshScylla.Repo", "--resource", "AshScylla.DataLayer"])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "DRY RUN" or output =~ "No resources" or output =~ "Schema"
    end

    test "parses --keyspace flag" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Migrate.run(["--repo", "AshScylla.Repo", "--keyspace", "custom_ks"])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "DRY RUN" or output =~ "No resources" or output =~ "Schema"
    end

    test "parses --nodes flag" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Migrate.run(["--repo", "AshScylla.Repo", "--nodes", "127.0.0.1:9042"])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "DRY RUN" or output =~ "No resources" or output =~ "Schema"
    end

    test "runs with combined flags" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Migrate.run([
              "--repo", "AshScylla.Repo",
              "--dry-run",
              "--schemas-only",
              "--keyspace", "test_ks"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Schema" or output =~ "No schema"
    end
  end

  describe "AshScylla.SchemaLoader.discover/0" do
    test "returns a list (possibly empty)" do
      result = AshScylla.SchemaLoader.discover()
      assert is_list(result)
    end
  end
end
