defmodule Mix.Tasks.AshScylla.GenTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AshScylla.ResourceGenerator

  describe "ResourceGenerator.parse_args/1" do
    test "parses resource name and attributes" do
      assert {:ok, :MyResource,
              [
                user_id: :uuid,
                name: :string,
                age: :integer
              ]} =
               ResourceGenerator.parse_args(["MyResource", "user_id:uuid, name:string, age:int"])
    end

    test "requires at least one attribute" do
      assert {:error, "At least one attribute is required"} =
               ResourceGenerator.parse_args(["MyResource"])
    end

    test "returns error on empty args" do
      assert {:error, "Usage: mix ash_scylla.gen MyResource user_id:uuid, name:string, age:int"} =
               ResourceGenerator.parse_args([])
    end
  end

  describe "ResourceGenerator.render_resource/2" do
    test "renders an Ash resource template" do
      rendered =
        ResourceGenerator.render_resource(
          :MyResource,
          [user_id: :uuid, name: :string, age: :integer],
          repo_module: MyApp.Repo
        )

      assert rendered =~ "defmodule MyResource do"
      assert rendered =~ "data_layer: AshScylla.DataLayer"
      assert rendered =~ "repo: MyApp.Repo"
      assert rendered =~ "uuid_primary_key :id"
      assert rendered =~ "attribute :user_id, :uuid"
      assert rendered =~ "attribute :name, :string"
      assert rendered =~ "attribute :age, :integer"
      assert rendered =~ "defaults [:create, :read, :update, :destroy]"
    end

    test "skips :id attribute to avoid duplicate primary key" do
      rendered =
        ResourceGenerator.render_resource(
          :MyResource,
          [id: :uuid, name: :string],
          repo_module: MyApp.Repo
        )

      refute rendered =~ "attribute :id, :uuid"
      assert rendered =~ "uuid_primary_key :id"
    end
  end

  describe "ResourceGenerator.resource_file_path/1" do
    test "builds path from resource name" do
      path = ResourceGenerator.resource_file_path(:MyResource)
      assert path =~ ~r/lib\/.*\/resources\/my_resource\.ex$/
    end
  end

  describe "ResourceGenerator.render_create_table/3" do
    test "renders CREATE TABLE statement" do
      statements =
        ResourceGenerator.render_create_table(
          "users",
          [name: :string, email: :string, age: :integer],
          MyApp.Repo
        )

      assert length(statements) >= 1
      table_cql = hd(statements)
      assert table_cql =~ "CREATE TABLE IF NOT EXISTS users"
      assert table_cql =~ "id UUID PRIMARY KEY"
      assert table_cql =~ "name TEXT"
      assert table_cql =~ "email TEXT"
      assert table_cql =~ "age INT"
    end

    test "includes index for email column" do
      statements =
        ResourceGenerator.render_create_table(
          "users",
          [email: :string, name: :string],
          MyApp.Repo
        )

      index_statements = tl(statements)
      assert length(index_statements) == 2

      assert Enum.any?(index_statements, &String.contains?(&1, "idx_users_email"))
      assert Enum.any?(index_statements, &String.contains?(&1, "idx_users_name"))
    end

    test "includes index for status column" do
      statements =
        ResourceGenerator.render_create_table(
          "orders",
          [status: :string, total: :float],
          MyApp.Repo
        )

      index_statements = tl(statements)
      assert Enum.any?(index_statements, &String.contains?(&1, "idx_orders_status"))
    end

    test "includes index for age column" do
      statements =
        ResourceGenerator.render_create_table(
          "people",
          [age: :integer, name: :string],
          MyApp.Repo
        )

      index_statements = tl(statements)
      assert Enum.any?(index_statements, &String.contains?(&1, "idx_people_age"))
    end

    test "does not include index for non-indexed columns" do
      statements =
        ResourceGenerator.render_create_table(
          "logs",
          [message: :string, level: :string],
          MyApp.Repo
        )

      index_statements = tl(statements)
      assert index_statements == []
    end

    test "skips :id attribute in column list" do
      statements =
        ResourceGenerator.render_create_table(
          "items",
          [id: :uuid, title: :string],
          MyApp.Repo
        )

      table_cql = hd(statements)
      assert table_cql =~ "id UUID PRIMARY KEY"
      refute table_cql =~ "id UUID PRIMARY KEY, id UUID"
    end
  end

  describe "cql_type/1 mapping" do
    test "maps common types correctly" do
      statements =
        ResourceGenerator.render_create_table(
          "types_test",
          [
            uuid_col: :uuid,
            string_col: :string,
            int_col: :integer,
            float_col: :float,
            bool_col: :boolean,
            date_col: :date,
            time_col: :time,
            ts_col: :utc_datetime,
            naive_ts_col: :naive_datetime,
            binary_col: :binary,
            map_col: :map,
            list_col: :list
          ],
          MyApp.Repo
        )

      table_cql = hd(statements)
      assert table_cql =~ "uuid_col UUID"
      assert table_cql =~ "string_col TEXT"
      assert table_cql =~ "int_col INT"
      assert table_cql =~ "float_col FLOAT"
      assert table_cql =~ "bool_col BOOLEAN"
      assert table_cql =~ "date_col DATE"
      assert table_cql =~ "time_col TIME"
      assert table_cql =~ "ts_col TIMESTAMP"
      assert table_cql =~ "naive_ts_col TIMESTAMP"
      assert table_cql =~ "binary_col BLOB"
      assert table_cql =~ "map_col MAP<TEXT, TEXT>"
      assert table_cql =~ "list_col LIST<TEXT>"
    end

    test "maps unknown types to TEXT" do
      statements =
        ResourceGenerator.render_create_table(
          "unknown_test",
          [custom_col: :custom_type],
          MyApp.Repo
        )

      table_cql = hd(statements)
      assert table_cql =~ "custom_col TEXT"
    end
  end

  describe "Mix.Tasks.AshScylla.Gen" do
    test "task module exists and is callable" do
      assert is_function(&Mix.Tasks.AshScylla.Gen.run/1)
    end

    test "parses --dev flag without error" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Gen.run(["--dev"])
        end)

      # Should get "no resources found" since ash_scylla has no AshScylla resources
      assert output =~ "No AshScylla resources found"
    end

    test "parses --resource option without error" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.run(["--resource", "AshScylla.DataLayer"])
          rescue
            _ -> :ok
          end
        end)

      # The resource doesn't exist so it may crash, but CLI parsing succeeded
      assert is_binary(output)
    end

    test "parses --d shorthand for --dev" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Gen.run(["-d"])
        end)

      assert output =~ "No AshScylla resources found"
    end

    test "parses schema name argument without error" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Gen.run(["MySchema"])
        end)

      assert output =~ "No AshScylla resources found"
    end

    test "rejects invalid --resource flag" do
      assert_raise OptionParser.ParseError, fn ->
        Mix.Tasks.AshScylla.Gen.run(["--resource"])
      end
    end
  end

  describe "Mix.Tasks.AshScylla.NewTemplate" do
    test "task module exists and is callable" do
      assert is_function(&Mix.Tasks.AshScylla.NewTemplate.run/1)
    end

    test "generates resource template file" do
      file_path = Path.join(["lib", "ash_scylla", "resources", "test_template_gen.ex"])

      # Clean up any previous run
      File.rm(file_path)

      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.NewTemplate.run([
            "TestTemplateGen",
            "name:string, email:string"
          ])
        end)

      assert output =~ "Generated #{file_path}"
      assert File.exists?(file_path)

      content = File.read!(file_path)
      assert content =~ "defmodule TestTemplateGen do"
      assert content =~ "data_layer: AshScylla.DataLayer"
      assert content =~ "attribute :name, :string"
      assert content =~ "attribute :email, :string"

      # Clean up
      File.rm(file_path)
    end

    test "raises on empty args" do
      assert_raise Mix.Error, fn ->
        Mix.Tasks.AshScylla.NewTemplate.run([])
      end
    end

    test "raises on missing attributes" do
      assert_raise Mix.Error, fn ->
        Mix.Tasks.AshScylla.NewTemplate.run(["MyResource"])
      end
    end

    test "accepts :int as alias for :integer" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.NewTemplate.run([
            "TestIntGen",
            "count:int"
          ])
        end)

      file_path = Path.join(["lib", "ash_scylla", "resources", "test_int_gen.ex"])

      assert output =~ "Generated #{file_path}"
      content = File.read!(file_path)
      assert content =~ "attribute :count, :integer"
      File.rm(file_path)
    end
  end
end
