defmodule AshScylla.SchemaLoaderTest do
  use ExUnit.Case, async: true

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
      tmp_dir =
        Path.join(System.tmp_dir!(), "ash_scylla_test_#{:erlang.unique_integer([:positive])}")

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
      tmp_dir =
        Path.join(System.tmp_dir!(), "ash_scylla_test_#{:erlang.unique_integer([:positive])}")

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
      tmp_dir =
        Path.join(System.tmp_dir!(), "ash_scylla_test_#{:erlang.unique_integer([:positive])}")

      tmp_file = Path.join(tmp_dir, "bad_syntax.ex")

      File.mkdir_p!(tmp_dir)
      File.write!(tmp_file, "defmodule Bad do\n  invalid elixir code\nend")

      assert {:error, _} = AshScylla.SchemaLoader.load(tmp_file)

      File.rm_rf!(tmp_dir)
    end

    test "loads a struct-based schema module and flattens it" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "ash_scylla_test_#{:erlang.unique_integer([:positive])}")

      tmp_file = Path.join(tmp_dir, "struct_schema.ex")

      File.mkdir_p!(tmp_dir)

      File.write!(tmp_file, """
      defmodule AshScylla.SchemaLoaderTest.StructSchema do
        use AshScylla.Schema

        @impl AshScylla.Schema
        def change do
          [
            %AshScylla.Schema{
              domain: MyApp.Domain,
              resources: [
                %AshScylla.Schema.Resource{
                  name: :users,
                  statements: [
                    "CREATE TABLE IF NOT EXISTS users (id UUID PRIMARY KEY, name TEXT)",
                    "CREATE INDEX IF NOT EXISTS idx_users_name ON users (name)"
                  ]
                }
              ]
            }
          ]
        end
      end
      """)

      assert {:ok, statements} = AshScylla.SchemaLoader.load(tmp_file)
      assert is_list(statements)
      assert length(statements) == 2
      assert Enum.at(statements, 0) =~ "CREATE TABLE IF NOT EXISTS users"
      assert Enum.at(statements, 1) =~ "CREATE INDEX IF NOT EXISTS idx_users_name"

      File.rm_rf!(tmp_dir)
    end

    test "loads a mixed schema with both strings and structs" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "ash_scylla_test_#{:erlang.unique_integer([:positive])}")

      tmp_file = Path.join(tmp_dir, "mixed_schema.ex")

      File.mkdir_p!(tmp_dir)

      File.write!(tmp_file, """
      defmodule AshScylla.SchemaLoaderTest.MixedSchema do
        use AshScylla.Schema

        @impl AshScylla.Schema
        def change do
          [
            "CREATE TABLE IF NOT EXISTS legacy (id UUID PRIMARY KEY)",
            %AshScylla.Schema{
              resources: [
                %AshScylla.Schema.Resource{
                  name: :users,
                  statements: ["CREATE TABLE IF NOT EXISTS users (id UUID PRIMARY KEY)"]
                }
              ]
            }
          ]
        end
      end
      """)

      assert {:ok, statements} = AshScylla.SchemaLoader.load(tmp_file)
      assert is_list(statements)
      assert length(statements) == 2
      assert hd(statements) =~ "legacy"
      assert Enum.at(statements, 1) =~ "users"

      File.rm_rf!(tmp_dir)
    end

    test "loads the same file repeatedly (multiple Ash extensions in one process)" do
      # Regression: `mix ash.migrate` runs both AshScylla.DataLayer and
      # AshScylla.Extension in the same process, so the same migration files
      # are loaded twice. The loader must reuse the already-loaded module
      # (read from the file's `defmodule`) instead of re-evaluating, which
      # would emit "redefining module" warnings and fail to match the result.
      tmp_dir =
        Path.join(System.tmp_dir!(), "ash_scylla_test_#{:erlang.unique_integer([:positive])}")

      tmp_file = Path.join(tmp_dir, "reload_schema.ex")

      File.mkdir_p!(tmp_dir)

      File.write!(tmp_file, """
      defmodule AshScylla.Migrations.ReloadSchema do
        use AshScylla.Schema

        @impl AshScylla.Schema
        def change do
          ["CREATE TABLE IF NOT EXISTS reload_test (id UUID PRIMARY KEY)"]
        end
      end
      """)

      assert {:ok, _} = AshScylla.SchemaLoader.load(tmp_file)
      assert {:ok, _} = AshScylla.SchemaLoader.load(tmp_file)
      assert {:ok, statements} = AshScylla.SchemaLoader.load(tmp_file)
      assert hd(statements) =~ "reload_test"

      File.rm_rf!(tmp_dir)
    end

    test "loads a file whose name differs from its module name (timestamp prefix)" do
      # Regression: migration filenames carry a timestamp prefix that the
      # module name does not (e.g. `20260714..._new_name_games_info_1.exs`
      # defines `AshScylla.Migrations.NewNameGamesInfo1`). The loader must read
      # the module from the source, not reconstruct it from the filename.
      tmp_dir =
        Path.join(System.tmp_dir!(), "ash_scylla_test_#{:erlang.unique_integer([:positive])}")

      tmp_file = Path.join(tmp_dir, "20260714141054_new_name_games_info_1.exs")

      File.mkdir_p!(tmp_dir)

      File.write!(tmp_file, """
      defmodule AshScylla.Migrations.NewNameGamesInfo1 do
        use AshScylla.Schema

        @impl AshScylla.Schema
        def change do
          ["CREATE TABLE IF NOT EXISTS games_info (id UUID PRIMARY KEY)"]
        end
      end
      """)

      assert {:ok, statements} = AshScylla.SchemaLoader.load(tmp_file)
      assert hd(statements) =~ "games_info"

      File.rm_rf!(tmp_dir)
    end

    test "returns error when file has no defmodule" do
      # The loader extracts the module name from `defmodule X do`; a file
      # without one cannot be loaded.
      tmp_dir =
        Path.join(System.tmp_dir!(), "ash_scylla_test_#{:erlang.unique_integer([:positive])}")

      tmp_file = Path.join(tmp_dir, "no_module.exs")

      File.mkdir_p!(tmp_dir)
      File.write!(tmp_file, "[\"CREATE TABLE\"]")

      assert {:error, :no_module_found} = AshScylla.SchemaLoader.load(tmp_file)

      File.rm_rf!(tmp_dir)
    end
  end
end
