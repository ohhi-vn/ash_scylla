defmodule AshScylla.DataLayer.SchemaMigrationTest do
  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.SchemaMigration

  describe "diff_columns/2" do
    test "detects added columns when live columns are empty" do
      attrs = Ash.Resource.Info.attributes(AshScylla.TestResource)
      result = SchemaMigration.diff_columns(attrs, [])
      assert result.add != []
      assert result.remove == []
    end

    test "detects no changes when all columns match" do
      attrs = Ash.Resource.Info.attributes(AshScylla.TestResource)
      live = Enum.map(attrs, fn a -> %{name: to_string(a.name), type: "text"} end)
      result = SchemaMigration.diff_columns(attrs, live)
      assert result.add == []
      assert result.remove == []
    end

    test "detects removed columns" do
      attrs = Ash.Resource.Info.attributes(AshScylla.TestResource)
      extra = [%{name: "obsolete_col", type: "text"}]
      live = Enum.map(attrs, fn a -> %{name: to_string(a.name), type: "text"} end) ++ extra
      result = SchemaMigration.diff_columns(attrs, live)
      assert result.remove == [:obsolete_col]
    end

    test "change_type is always empty (ScyllaDB limitation)" do
      attrs = Ash.Resource.Info.attributes(AshScylla.TestResource)
      result = SchemaMigration.diff_columns(attrs, [])
      assert result.change_type == []
    end

    test "detects add and remove simultaneously" do
      attrs = Ash.Resource.Info.attributes(AshScylla.TestResource)
      live = [%{name: "legacy_field", type: "text"}]
      result = SchemaMigration.diff_columns(attrs, live)
      assert result.add != []
      assert :legacy_field in result.remove
    end
  end

  describe "generate_add_columns/2" do
    test "generates ALTER TABLE for existing attributes" do
      statements = SchemaMigration.generate_add_columns(AshScylla.TestResource, [:name])
      assert length(statements) == 1
      assert hd(statements) =~ "ALTER TABLE"
      assert hd(statements) =~ ~s("name")
    end

    test "generates statements for multiple columns" do
      statements =
        SchemaMigration.generate_add_columns(AshScylla.TestResource, [:name, :email])

      assert length(statements) == 2
      assert Enum.all?(statements, &String.contains?(&1, "ALTER TABLE"))
    end

    test "skips unknown columns with warning" do
      statements =
        SchemaMigration.generate_add_columns(AshScylla.TestResource, [:nonexistent_col])

      assert statements == []
    end

    test "includes keyspace qualifier when resource has keyspace" do
      statements = SchemaMigration.generate_add_columns(AshScylla.TestResource, [:name])

      assert hd(statements) =~ ~s("ash_scylla_test")
    end
  end

  describe "generate_new_indexes/2" do
    test "generates CREATE INDEX for new indexes when no live indexes exist" do
      statements =
        SchemaMigration.generate_new_indexes(AshScylla.TestResourceWithIndexes, [])

      assert length(statements) > 0
      assert Enum.all?(statements, &String.contains?(&1, "CREATE INDEX IF NOT EXISTS"))
    end

    test "skips indexes that already exist in live schema" do
      existing = [%{index_name: "idx_test_users_email", kind: "COMPOSITES", options: ""}]
      statements = SchemaMigration.generate_new_indexes(AshScylla.TestResourceWithIndexes, existing)

      refute Enum.any?(statements, &String.contains?(&1, "idx_test_users_email"))
    end

    test "includes indexes with custom names" do
      statements =
        SchemaMigration.generate_new_indexes(AshScylla.TestResourceWithIndexes, [])

      named =
        Enum.filter(statements, &String.contains?(&1, "idx_user_status_"))

      assert length(named) > 0
    end
  end

  describe "table_not_found_error?/1" do
    test "returns true for error with unconfigured table message" do
      assert SchemaMigration.table_not_found_error?(%{message: "unconfigured table users"})
    end

    test "returns false for error without unconfigured table message" do
      refute SchemaMigration.table_not_found_error?(%{message: "some other error"})
    end

    test "returns false for non-map error" do
      refute SchemaMigration.table_not_found_error?("string error")
      refute SchemaMigration.table_not_found_error?(:atom_error)
      refute SchemaMigration.table_not_found_error?(nil)
    end

    test "returns false for map without message key" do
      refute SchemaMigration.table_not_found_error?(%{foo: "bar"})
    end
  end

  describe "fetch_table_schema/2" do
    defmodule MockSchemaRepo do
      def query(_query, _params, _opts) do
        {:ok,
         %{
           content: [
             ["id", "uuid", "partition_key", "0", "none"],
             ["name", "text", "regular", "1", "none"]
           ],
           columns: [
             {"system_schema", "columns", "column_name", nil},
             {"system_schema", "columns", "type", nil},
             {"system_schema", "columns", "kind", nil},
             {"system_schema", "columns", "position", nil},
             {"system_schema", "columns", "clustering_order", nil}
           ]
         }}
      end
    end

    defmodule MockSchemaEmptyRepo do
      def query(_query, _params, _opts) do
        {:ok, %{content: [], columns: []}}
      end
    end

    defmodule MockFailingSchemaRepo do
      def query(_query, _params, _opts) do
        {:error, :connection_error}
      end
    end

    test "fetches columns from repo result" do
      assert {:ok, schema} =
               SchemaMigration.fetch_table_schema(AshScylla.TestResource, MockSchemaRepo)

      assert schema.columns != []
      assert schema.keyspace == "ash_scylla_test"
    end

    test "handles repo with no columns (empty result)" do
      assert {:ok, schema} =
               SchemaMigration.fetch_table_schema(AshScylla.TestResource, MockSchemaEmptyRepo)

      assert schema.columns == []
    end

    test "returns error when repo query fails" do
      assert {:error, :connection_error} =
               SchemaMigration.fetch_table_schema(
                 AshScylla.TestResource,
                 MockFailingSchemaRepo
               )
    end
  end

  describe "plan/2" do
    defmodule MockPlanRepo do
      def query(_query, _params, _opts) do
        {:ok, %{content: [], columns: []}}
      end
    end

    test "returns {:ok, statements} for resource with no live schema" do
      assert {:ok, statements} =
               SchemaMigration.plan(AshScylla.TestResource, MockPlanRepo)

      assert is_list(statements)
    end
  end

  describe "fetch_indexes/2" do
    defmodule MockIndexRepo do
      def query(_query, _params, _opts) do
        {:ok,
         %{
           content: [["idx_test_resource_name", "COMPOSITES", "{}"]],
           columns: [
             {"system_schema", "indexes", "index_name", nil},
             {"system_schema", "indexes", "kind", nil},
             {"system_schema", "indexes", "options", nil}
           ]
         }}
      end
    end

    defmodule MockFailingIndexRepo do
      def query(_query, _params, _opts) do
        {:error, :index_error}
      end
    end

    test "fetches indexes from repo" do
      assert {:ok, indexes} =
               SchemaMigration.fetch_indexes(AshScylla.TestResource, MockIndexRepo)

      assert length(indexes) > 0
      assert hd(indexes)[:index_name] == "idx_test_resource_name"
    end

    test "returns error when query fails" do
      assert {:error, :index_error} =
               SchemaMigration.fetch_indexes(
                 AshScylla.TestResource,
                 MockFailingIndexRepo
               )
    end
  end

  describe "fetch_materialized_views/2" do
    defmodule MockViewRepo do
      def query(_query, _params, _opts) do
        {:ok,
         %{
           content: [["test_view", "test_resource", "id IS NOT NULL", true, ["id"]]],
           columns: [
             {"system_schema", "views", "view_name", nil},
             {"system_schema", "views", "base_table_name", nil},
             {"system_schema", "views", "where_clause", nil},
             {"system_schema", "views", "include_all_columns", nil},
             {"system_schema", "views", "columns", nil}
           ]
         }}
      end
    end

    defmodule MockFailingViewRepo do
      def query(_query, _params, _opts) do
        {:error, :view_error}
      end
    end

    test "fetches materialized views from repo" do
      assert {:ok, views} =
               SchemaMigration.fetch_materialized_views(
                 AshScylla.TestResource,
                 MockViewRepo
               )

      assert is_list(views)
    end

    test "returns error when query fails" do
      assert {:error, :view_error} =
               SchemaMigration.fetch_materialized_views(
                 AshScylla.TestResource,
                 MockFailingViewRepo
               )
    end
  end

  describe "diff/2 error paths" do
    defmodule MockTableNotFoundRepo do
      def query(_query, _params, _opts) do
        {:error, %{message: "unconfigured table test_resource"}}
      end
    end

    defmodule MockGenericErrorRepo do
      def query(_query, _params, _opts) do
        {:error, :generic_error}
      end
    end

    test "returns full DDL when table not found" do
      statements = SchemaMigration.diff(AshScylla.TestResource, MockTableNotFoundRepo)
      assert length(statements) > 0
      assert Enum.all?(statements, &is_binary/1)
    end

    test "returns empty list for unknown errors" do
      assert SchemaMigration.diff(AshScylla.TestResource, MockGenericErrorRepo) == []
    end
  end

  describe "migrate/3" do
    defmodule MockNoChangeRepo do
      def query(_query, _params, _opts) do
        {:error, :generic_error}
      end
    end

    defmodule MockDryRunRepo do
      def query(_query, _params, _opts) do
        {:error, %{message: "unconfigured table for_migrate_test"}}
      end
    end

    test "returns {:ok, []} when no changes needed" do
      assert {:ok, []} = SchemaMigration.migrate(AshScylla.TestResource, MockNoChangeRepo)
    end

    test "returns {:ok, statements} in dry_run mode" do
      assert {:ok, statements} =
               SchemaMigration.migrate(AshScylla.TestResource, MockDryRunRepo, dry_run: true)

      assert is_list(statements)
      assert length(statements) > 0
      assert Enum.all?(statements, &is_binary/1)
    end
  end
end
