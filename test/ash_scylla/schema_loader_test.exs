defmodule AshScylla.SchemaLoaderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "discover/0" do
    test "returns list of schema file paths" do
      files = AshScylla.SchemaLoader.discover()
      assert is_list(files)
    end

    test "returns sorted file list" do
      files = AshScylla.SchemaLoader.discover()
      assert files == Enum.sort(files)
    end

    test "returns empty list when no priv/migrations directory exists" do
      # In test environment, priv/migrations may not exist
      files = AshScylla.SchemaLoader.discover()
      assert is_list(files)
    end
  end

  describe "load/1" do
    test "loads a valid schema module" do
      # Write a temporary schema file
      tmp_dir = Path.join(System.tmp_dir!(), "ash_scylla_test_#{:erlang.unique_integer([:positive])}")
      tmp_file = Path.join(tmp_dir, "test_schema.ex")

      File.mkdir_p!(tmp_dir)

      File.write!(tmp_file, """
      defmodule AshScylla.SchemaLoaderTest.TempSchema do
        use AshScylla.Schema

        @impl AshScylla.Schema
        def change do
          ["CREATE TABLE IF NOT EXISTS temp_test (id UUID PRIMARY KEY, val TEXT)"]
        end
      end
      """)

      assert {:ok, statements} = AshScylla.SchemaLoader.load(tmp_file)
      assert is_list(statements)
      assert length(statements) == 1
      assert hd(statements) =~ "CREATE TABLE IF NOT EXISTS temp_test"

      # Cleanup
      File.rm_rf!(tmp_dir)
    end

    test "returns error for file without change/0" do
      tmp_dir = Path.join(System.tmp_dir!(), "ash_scylla_test_#{:erlang.unique_integer([:positive])}")
      tmp_file = Path.join(tmp_dir, "no_change.ex")

      File.mkdir_p!(tmp_dir)

      File.write!(tmp_file, """
      defmodule AshScylla.SchemaLoaderTest.NoChange do
      end
      """)

      assert {:error, :no_change_function} = AshScylla.SchemaLoader.load(tmp_file)

      File.rm_rf!(tmp_dir)
    end

    test "returns error for non-existent file" do
      assert {:error, _} = AshScylla.SchemaLoader.load("/nonexistent/path/schema.ex")
    end

    test "returns error for file with syntax errors" do
      tmp_dir = Path.join(System.tmp_dir!(), "ash_scylla_test_#{:erlang.unique_integer([:positive])}")
      tmp_file = Path.join(tmp_dir, "bad_syntax.ex")

      File.mkdir_p!(tmp_dir)
      File.write!(tmp_file, "defmodule Bad do\n  invalid elixir code\nend")

      assert {:error, _} = AshScylla.SchemaLoader.load(tmp_file)

      File.rm_rf!(tmp_dir)
    end
  end
end
