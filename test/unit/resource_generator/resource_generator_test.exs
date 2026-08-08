defmodule AshScylla.ResourceGeneratorTest do
  use ExUnit.Case, async: true

  alias AshScylla.ResourceGenerator

  describe "parse_args/1" do
    test "parses resource name and attributes" do
      assert {:ok, resource_name, attrs} =
               ResourceGenerator.parse_args(["MyResource", "user_id:uuid, name:string"])

      assert resource_name == :MyResource
      assert attrs == [user_id: :uuid, name: :string]
    end

    test "normalizes int to integer" do
      assert {:ok, _name, attrs} =
               ResourceGenerator.parse_args(["MyResource", "age:int"])

      assert attrs == [age: :integer]
    end

    test "handles colon-prefixed types" do
      assert {:ok, _name, attrs} =
               ResourceGenerator.parse_args(["MyResource", "count::integer"])

      assert attrs == [count: :integer]
    end

    test "rejects invalid resource names" do
      assert {:error, _} = ResourceGenerator.parse_args(["123invalid", "name:string"])
    end

    test "rejects missing args" do
      assert {:error, _} = ResourceGenerator.parse_args([])
    end

    test "rejects empty attributes" do
      assert {:error, _} = ResourceGenerator.parse_args(["MyResource"])
    end

    test "parses domain-prefixed resource name" do
      assert {:ok, name, _} =
               ResourceGenerator.parse_args([
                 "MyApp.MyDomain.MyResource",
                 "name:string"
               ])

      assert name == :"MyApp.MyDomain.MyResource"
    end
  end

  describe "parse_args/2" do
    test "respects --resource option" do
      assert {:ok, name, _} =
               ResourceGenerator.parse_args(
                 ["MyResource", "name:string"],
                 resource: :"MyApp.Custom.Resource"
               )

      assert name == :"MyApp.Custom.Resource"
    end

    test "prepends --domain to resource name" do
      assert {:ok, name, _} =
               ResourceGenerator.parse_args(
                 ["User", "name:string"],
                 domain: :"MyApp.MyDomain"
               )

      assert name == MyApp.MyDomain.User
    end

    test "falls through to positional name when no opts" do
      assert {:ok, name, _} =
               ResourceGenerator.parse_args(["MyResource", "name:string"], [])

      assert name == :MyResource
    end

    test "propagates parse error" do
      assert {:error, _} = ResourceGenerator.parse_args([], [])
    end
  end

  describe "parse_args/2 with strings" do
    test "accepts two string arguments" do
      assert {:ok, name, attrs} =
               ResourceGenerator.parse_args("MyResource", "name:string, age:int")

      assert name == :MyResource
      assert attrs == [name: :string, age: :integer]
    end
  end

  describe "render_resource/3" do
    test "renders basic resource" do
      output =
        ResourceGenerator.render_resource(
          :"Elixir.MyApp.User",
          [user_id: :uuid, name: :string],
          repo_module: :"Elixir.MyApp.Repo"
        )

      assert output =~ "defmodule MyApp.User do"
      assert output =~ "data_layer: AshScylla.DataLayer"
      assert output =~ "repo: MyApp.Repo"
      assert output =~ "uuid_primary_key :id"
      assert output =~ "attribute :user_id, :uuid"
      assert output =~ "attribute :name, :string"
    end

    test "renders resource with domain" do
      output =
        ResourceGenerator.render_resource(
          :"Elixir.MyApp.User",
          [name: :string],
          repo_module: :"Elixir.MyApp.Repo",
          domain: :"Elixir.MyApp.Domain"
        )

      assert output =~ "domain: MyApp.Domain"
    end

    test "omits :id from attributes block" do
      output =
        ResourceGenerator.render_resource(
          :"Elixir.MyApp.User",
          [id: :uuid, name: :string],
          repo_module: :"Elixir.MyApp.Repo"
        )

      refute output =~ "attribute :id"
      assert output =~ "attribute :name"
    end

    test "uses default repo module when not provided" do
      output = ResourceGenerator.render_resource(:"Elixir.MyApp.User", name: :string)
      assert output =~ "repo: "
    end
  end

  describe "resource_file_path/1" do
    test "returns a path under lib" do
      path = ResourceGenerator.resource_file_path(:"Elixir.MyApp.User")
      assert String.starts_with?(path, "lib/")
      assert String.ends_with?(path, ".ex")
    end
  end

  describe "render_create_table/3" do
    test "generates CREATE TABLE with PK" do
      statements = ResourceGenerator.render_create_table("users", [id: :uuid, name: :string], nil)
      assert statements != []
      assert hd(statements) =~ "CREATE TABLE IF NOT EXISTS users"
      assert hd(statements) =~ "id UUID"
      assert hd(statements) =~ "name TEXT"
    end

    test "generates index for name column" do
      statements =
        ResourceGenerator.render_create_table("users", [id: :uuid, name: :string], nil)

      assert Enum.any?(statements, &String.contains?(&1, "idx_users_name"))
    end

    test "generates index for email column" do
      statements =
        ResourceGenerator.render_create_table("users", [id: :uuid, email: :string], nil)

      assert Enum.any?(statements, &String.contains?(&1, "idx_users_email"))
    end

    test "generates index for status column" do
      statements =
        ResourceGenerator.render_create_table("users", [id: :uuid, status: :string], nil)

      assert Enum.any?(statements, &String.contains?(&1, "idx_users_status"))
    end

    test "handles composite primary key" do
      statements =
        ResourceGenerator.render_create_table("events", [id: :uuid, ts: :uuid, data: :text], nil)

      table_cql = hd(statements)
      assert table_cql =~ "id UUID"
      assert table_cql =~ "ts UUID"
    end

    test "handles no uuid columns" do
      statements =
        ResourceGenerator.render_create_table("config", [key: :string, value: :string], nil)

      table_cql = hd(statements)
      assert table_cql =~ "key TEXT"
      assert table_cql =~ "value TEXT"
    end
  end
end
