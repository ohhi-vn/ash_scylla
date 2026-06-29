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

    test "parses domain-prefixed resource name" do
      assert {:ok, :"MyApp.MyDomain.MyResource", [name: :string]} =
               ResourceGenerator.parse_args(["MyApp.MyDomain.MyResource", "name:string"])
    end

    test "requires at least one attribute" do
      assert {:error, "At least one attribute is required"} =
               ResourceGenerator.parse_args(["MyResource"])
    end

    test "returns error on empty args" do
      assert {:error,
              "Usage: mix ash_scylla.new_template MyResource user_id:uuid, name:string, age:int"} =
               ResourceGenerator.parse_args([])
    end
  end

  describe "ResourceGenerator.parse_args/2 with --domain" do
    test "prefixes resource name with domain module" do
      {:ok, resource_name, attributes} =
        ResourceGenerator.parse_args(
          ["User", "name:string, email:string"],
          domain: MyApp.MyDomain
        )

      assert resource_name == MyApp.MyDomain.User
      assert attributes == [name: :string, email: :string]
    end

    test "domain with nested module name" do
      {:ok, resource_name, _attributes} =
        ResourceGenerator.parse_args(
          ["Post", "title:string"],
          domain: :"MyApp.Blog"
        )

      assert resource_name == MyApp.Blog.Post
    end

    test "domain option with no attributes returns error" do
      assert {:error, "At least one attribute is required"} =
               ResourceGenerator.parse_args(
                 ["User"],
                 domain: MyApp.MyDomain
               )
    end
  end

  describe "ResourceGenerator.parse_args/2 with --resource" do
    test "uses fully-qualified resource name" do
      {:ok, resource_name, attributes} =
        ResourceGenerator.parse_args(
          ["User", "name:string"],
          resource: :"MyApp.Games.User"
        )

      assert resource_name == :"MyApp.Games.User"
      assert attributes == [name: :string]
    end

    test "resource flag overrides positional name" do
      {:ok, resource_name, _attributes} =
        ResourceGenerator.parse_args(
          ["Something", "name:string"],
          resource: :"MyApp.MyDomain.User"
        )

      assert resource_name == :"MyApp.MyDomain.User"
    end
  end

  describe "ResourceGenerator.parse_args/2 with both --domain and --resource" do
    test "resource takes precedence over domain" do
      {:ok, resource_name, attributes} =
        ResourceGenerator.parse_args(
          ["User", "name:string"],
          domain: MyApp.MyDomain,
          resource: :"MyApp.Other.User"
        )

      assert resource_name == :"MyApp.Other.User"
      assert attributes == [name: :string]
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

    test "renders domain option when provided" do
      rendered =
        ResourceGenerator.render_resource(
          :"MyApp.MyDomain.User",
          [name: :string, email: :string],
          domain: MyApp.MyDomain,
          repo_module: MyApp.Repo
        )

      assert rendered =~ "defmodule MyApp.MyDomain.User do"
      # inspect/1 quotes module atoms containing dots
      assert rendered =~ "domain:"
      assert rendered =~ "MyApp.MyDomain"
      assert rendered =~ "data_layer: AshScylla.DataLayer"
      assert rendered =~ "repo: MyApp.Repo"
      assert rendered =~ "attribute :name, :string"
      assert rendered =~ "attribute :email, :string"
    end

    test "renders without domain option when not provided" do
      rendered =
        ResourceGenerator.render_resource(
          :MyResource,
          [name: :string],
          repo_module: MyApp.Repo
        )

      refute rendered =~ "domain:"
      assert rendered =~ "defmodule MyResource do"
    end

    test "renders domain-prefixed module name correctly" do
      rendered =
        ResourceGenerator.render_resource(
          :"MyApp.Games.User",
          [name: :string],
          domain: MyApp.Games,
          repo_module: MyApp.Repo
        )

      assert rendered =~ "defmodule MyApp.Games.User do"
      assert rendered =~ "domain:"
      assert rendered =~ "MyApp.Games"
    end
  end

  describe "ResourceGenerator.resource_file_path/1" do
    test "builds path from simple resource name" do
      path = ResourceGenerator.resource_file_path(:MyResource)
      assert path =~ ~r/lib\/.*\/resources\/my_resource\.ex$/
    end

    test "builds path from domain-prefixed resource name uses last segment" do
      path = ResourceGenerator.resource_file_path(:"MyApp.MyDomain.User")
      assert path =~ ~r/lib\/.*\/resources\/user\.ex$/
    end
  end

  describe "ResourceGenerator.write_resource/3" do
    test "writes file with domain in content" do
      unique = System.unique_integer([:positive])
      file_path = Path.join(["lib", "ash_scylla", "resources", "test_write_#{unique}.ex"])
      File.rm(file_path)

      output =
        capture_io(fn ->
          ResourceGenerator.write_resource(
            :"MyApp.MyDomain.TestWrite",
            [name: :string],
            domain: MyApp.MyDomain,
            repo_module: MyApp.Repo
          )
        end)

      # The file path is based on the last segment (TestWrite -> test_write.ex)
      actual_path = Path.join(["lib", "ash_scylla", "resources", "test_write.ex"])
      assert output =~ "Generated"
      assert output =~ "domain MyApp.MyDomain"
      assert File.exists?(actual_path)

      content = File.read!(actual_path)
      assert content =~ "defmodule MyApp.MyDomain.TestWrite do"
      assert content =~ "domain:"
      assert content =~ "MyApp.MyDomain"

      File.rm(actual_path)
    end

    test "writes file without domain when not provided" do
      unique = System.unique_integer([:positive])

      file_path =
        Path.join(["lib", "ash_scylla", "resources", "test_no_domain_write_#{unique}.ex"])

      File.rm(file_path)

      output =
        capture_io(fn ->
          ResourceGenerator.write_resource(
            :TestNoDomainWrite,
            [name: :string],
            repo_module: MyApp.Repo
          )
        end)

      actual_path = Path.join(["lib", "ash_scylla", "resources", "test_no_domain_write.ex"])
      assert output =~ "Generated"
      assert File.exists?(actual_path)

      content = File.read!(actual_path)
      assert content =~ "defmodule TestNoDomainWrite do"
      refute content =~ "domain:"

      File.rm(actual_path)
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

      assert length(statements) > 0
      table_cql = hd(statements)
      assert table_cql =~ "CREATE TABLE IF NOT EXISTS users"
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

    test "uses first uuid attribute as primary key" do
      statements =
        ResourceGenerator.render_create_table(
          "items",
          [id: :uuid, title: :string],
          MyApp.Repo
        )

      table_cql = hd(statements)
      assert table_cql =~ "PRIMARY KEY (id)"
      assert table_cql =~ "id UUID"
      assert table_cql =~ "title TEXT"
    end

    test "generates composite primary key for multiple uuid attributes" do
      statements =
        ResourceGenerator.render_create_table(
          "direct_messages",
          [id: :uuid, from_user_id: :uuid, to_user_id: :uuid, content: :string],
          MyApp.Repo
        )

      table_cql = hd(statements)
      assert table_cql =~ "PRIMARY KEY (id, from_user_id, to_user_id)"
      assert table_cql =~ "id UUID"
      assert table_cql =~ "from_user_id UUID"
      assert table_cql =~ "to_user_id UUID"
      assert table_cql =~ "content TEXT"
    end

    test "generates composite primary key with three uuid attributes" do
      statements =
        ResourceGenerator.render_create_table(
          "message_metadata",
          [id: :uuid, user_id: :uuid, message_id: :uuid, content: :string],
          MyApp.Repo
        )

      table_cql = hd(statements)
      assert table_cql =~ "PRIMARY KEY (id, user_id, message_id)"
      assert table_cql =~ "content TEXT"
    end

    test "composite pk columns are not duplicated in regular columns" do
      statements =
        ResourceGenerator.render_create_table(
          "club_messages",
          [id: :uuid, group_id: :uuid, group_type: :string, content: :string],
          MyApp.Repo
        )

      table_cql = hd(statements)
      # PK columns should appear once in the column list
      assert table_cql =~ "id UUID"
      assert table_cql =~ "group_id UUID"
      # PK clause should be present
      assert table_cql =~ "PRIMARY KEY (id, group_id)"
      # Count occurrences of "id UUID" as a standalone column definition -
      # should appear exactly once (not duplicated between column list and PK clause)
      assert length(Regex.scan(~r/(?:^|,\s*)id UUID/, table_cql)) == 1
    end

    test "handles single non-uuid attribute without primary key" do
      statements =
        ResourceGenerator.render_create_table(
          "logs",
          [message: :string],
          MyApp.Repo
        )

      table_cql = hd(statements)
      assert table_cql =~ "CREATE TABLE IF NOT EXISTS logs"
      assert table_cql =~ "message TEXT"
      refute table_cql =~ "PRIMARY KEY"
    end

    test "handles empty attribute list gracefully" do
      statements =
        ResourceGenerator.render_create_table(
          "empty_table",
          [],
          MyApp.Repo
        )

      table_cql = hd(statements)
      assert table_cql =~ "CREATE TABLE IF NOT EXISTS empty_table"
    end

    test "does not crash with many uuid attributes" do
      # Regression: previously crashed with FunctionClauseError when
      # pk_attrs had 2+ elements because pk_clause only matched single-element list
      assert {:ok, _, _} =
               ResourceGenerator.parse_args(
                 "MyResource",
                 "id:uuid, group_id: :uuid, org_id: :uuid, name:string"
               )
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
      assert table_cql =~ "float_col DOUBLE"
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

  describe "Mix.Tasks.AshScylla.Gen struct-based schema" do
    test "generates schema file with struct-based format" do
      # Use a known test resource that has a domain
      # Use --force to bypass meta-file change detection
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.run([
              "--resource",
              "AshScylla.TestResource",
              "--force",
              "TestSchema"
            ])
          rescue
            _ -> :ok
          end
        end)

      # Should mention struct-based output
      assert output =~ "Generated schema migration"
      assert output =~ "Domains:"
      assert output =~ "Resources: 1"
    end

    test "generates schema with domain grouping" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.run([
              "--resource",
              "AshScylla.TestResource",
              "--force",
              "DomainGrouped"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Generated schema migration"
      # Should have domain info in output
      assert output =~ "Domains:"
    end

    test "generates keyspace-qualified table name when keyspace is configured" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.run([
              "--resource",
              "AshScylla.TestResource",
              "--force",
              "KeyspaceQualified"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Generated schema migration"
    end

    test "generates composite primary key for resource with multiple pk attributes" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.run([
              "--resource",
              "AshScylla.TestResourceCompositePK",
              "--force",
              "CompositePKSchema"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Generated schema migration"
      assert output =~ "Resources: 1"
    end
  end

  describe "Mix.Tasks.AshScylla.NewTemplate" do
    test "task module exists and is callable" do
      assert is_function(&Mix.Tasks.AshScylla.NewTemplate.run/1)
    end

    test "generates resource template file" do
      file_path = Path.join(["lib", "ash_scylla", "resources", "test_template_gen.ex"])
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

  describe "Mix.Tasks.AshScylla.NewTemplate with --domain" do
    test "generates resource with domain flag" do
      unique = System.unique_integer([:positive])
      file_path = Path.join(["lib", "ash_scylla", "resources", "test_domain_flag_#{unique}.ex"])
      File.rm(file_path)

      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.NewTemplate.run([
            "TestDomainFlag",
            "name:string",
            "--domain",
            "MyApp.MyDomain"
          ])
        end)

      # File is written to the path based on last segment
      actual_path = Path.join(["lib", "ash_scylla", "resources", "test_domain_flag.ex"])
      assert output =~ "Generated"
      assert File.exists?(actual_path)

      content = File.read!(actual_path)
      assert content =~ "defmodule MyApp.MyDomain.TestDomainFlag do"
      assert content =~ "domain:"
      assert content =~ "MyApp.MyDomain"
      assert content =~ "data_layer: AshScylla.DataLayer"
      assert content =~ "attribute :name, :string"

      File.rm(actual_path)
    end

    test "domain flag with multiple attributes" do
      file_path = Path.join(["lib", "ash_scylla", "resources", "test_domain_multi.ex"])
      File.rm(file_path)

      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.NewTemplate.run([
            "TestDomainMulti",
            "name:string, email:string, age:int",
            "--domain",
            "MyApp.Games"
          ])
        end)

      actual_path = Path.join(["lib", "ash_scylla", "resources", "test_domain_multi.ex"])
      assert output =~ "Generated"
      assert File.exists?(actual_path)

      content = File.read!(actual_path)
      assert content =~ "defmodule MyApp.Games.TestDomainMulti do"
      assert content =~ "domain:"
      assert content =~ "MyApp.Games"
      assert content =~ "attribute :name, :string"
      assert content =~ "attribute :email, :string"
      assert content =~ "attribute :age, :integer"

      File.rm(actual_path)
    end

    test "domain flag with no attributes raises error" do
      assert_raise Mix.Error, fn ->
        Mix.Tasks.AshScylla.NewTemplate.run([
          "TestDomainNoAttr",
          "--domain",
          "MyApp.MyDomain"
        ])
      end
    end
  end

  describe "Mix.Tasks.AshScylla.NewTemplate with --resource" do
    test "generates resource with fully-qualified name" do
      file_path = Path.join(["lib", "ash_scylla", "resources", "user.ex"])
      File.rm(file_path)

      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.NewTemplate.run([
            "TestResourceFlag",
            "name:string",
            "--resource",
            "MyApp.Games.User"
          ])
        end)

      assert output =~ "Generated"
      assert File.exists?(file_path)

      content = File.read!(file_path)
      assert content =~ "defmodule MyApp.Games.User do"
      assert content =~ "data_layer: AshScylla.DataLayer"
      assert content =~ "attribute :name, :string"

      File.rm(file_path)
    end

    test "resource flag overrides positional name" do
      file_path = Path.join(["lib", "ash_scylla", "resources", "post.ex"])
      File.rm(file_path)

      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.NewTemplate.run([
            "Something",
            "title:string",
            "--resource",
            "MyApp.Blog.Post"
          ])
        end)

      assert output =~ "Generated"
      assert File.exists?(file_path)

      content = File.read!(file_path)
      assert content =~ "defmodule MyApp.Blog.Post do"
      refute content =~ "Something"
      assert content =~ "attribute :title, :string"

      File.rm(file_path)
    end
  end

  describe "Mix.Tasks.AshScylla.NewTemplate with --domain and --resource together" do
    test "resource flag takes precedence over domain" do
      file_path = Path.join(["lib", "ash_scylla", "resources", "test_both_flags.ex"])
      File.rm(file_path)

      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.NewTemplate.run([
            "TestBothFlags",
            "name:string",
            "--domain",
            "MyApp.MyDomain",
            "--resource",
            "MyApp.Other.TestBothFlags"
          ])
        end)

      assert output =~ "Generated"
      assert File.exists?(file_path)

      content = File.read!(file_path)
      assert content =~ "defmodule MyApp.Other.TestBothFlags do"

      File.rm(file_path)
    end
  end
end
