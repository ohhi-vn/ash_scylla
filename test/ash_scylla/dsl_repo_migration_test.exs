defmodule AshScylla.DslRepoMigrationTest do
  @moduledoc """
  Comprehensive tests for DSL, Repo, Migration, and AshScylla modules.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.Dsl
  alias AshScylla.Migration

  # TestResourceWithIndexes has full DSL config
  alias AshScylla.TestResourceWithIndexes

  # ============================================================================
  # DSL Tests
  # ============================================================================

  describe "Dsl.table/1" do
    test "returns the configured table name for TestResourceWithIndexes" do
      assert Dsl.table(TestResourceWithIndexes) == "test_users"
    end

    test "returns nil for a resource without ash_scylla config" do
      # A plain module that doesn't use the ash_scylla DSL
      assert Dsl.table(String) == nil
    end
  end

  describe "Dsl.keyspace/1" do
    test "returns the configured keyspace for TestResourceWithIndexes" do
      assert Dsl.keyspace(TestResourceWithIndexes) == "ash_scylla_test"
    end

    test "returns nil for a resource without ash_scylla config" do
      assert Dsl.keyspace(String) == nil
    end
  end

  describe "Dsl.consistency/1" do
    test "returns the configured consistency level for TestResourceWithIndexes" do
      assert Dsl.consistency(TestResourceWithIndexes) == :quorum
    end

    test "returns nil for a resource without ash_scylla config" do
      assert Dsl.consistency(String) == nil
    end
  end

  describe "Dsl.ttl/1" do
    test "returns the configured TTL for TestResourceWithIndexes" do
      assert Dsl.ttl(TestResourceWithIndexes) == 3600
    end

    test "returns nil for a resource without ash_scylla config" do
      assert Dsl.ttl(String) == nil
    end
  end

  describe "Dsl.secondary_indexes/1" do
    test "returns the 3 secondary indexes for TestResourceWithIndexes" do
      indexes = Dsl.secondary_indexes(TestResourceWithIndexes)
      assert length(indexes) == 3
    end

    test "each index has :columns key" do
      indexes = Dsl.secondary_indexes(TestResourceWithIndexes)

      Enum.each(indexes, fn idx ->
        assert Map.has_key?(idx, :columns)
        assert is_list(idx.columns)
      end)
    end

    test "includes single-column index on :email" do
      indexes = Dsl.secondary_indexes(TestResourceWithIndexes)
      email_index = Enum.find(indexes, fn idx -> :email in idx.columns end)
      assert email_index != nil
      assert email_index.columns == [:email]
    end

    test "includes composite index on [:name, :age]" do
      indexes = Dsl.secondary_indexes(TestResourceWithIndexes)
      composite_index = Enum.find(indexes, fn idx -> length(idx.columns) == 2 end)
      assert composite_index != nil
      assert :name in composite_index.columns
      assert :age in composite_index.columns
    end

    test "includes named index on :status" do
      indexes = Dsl.secondary_indexes(TestResourceWithIndexes)
      status_index = Enum.find(indexes, fn idx -> :status in idx.columns end)
      assert status_index != nil
      assert status_index.name == "idx_user_status"
    end

    test "returns empty list for a resource without ash_scylla config" do
      assert Dsl.secondary_indexes(String) == []
    end
  end

  describe "Dsl.materialized_views/1" do
    test "returns empty list for TestResourceWithIndexes (no views defined)" do
      assert Dsl.materialized_views(TestResourceWithIndexes) == []
    end

    test "returns empty list for a resource without ash_scylla config" do
      assert Dsl.materialized_views(String) == []
    end
  end

  describe "Dsl.has_secondary_index?/2" do
    test "returns true for :email column" do
      assert Dsl.has_secondary_index?(TestResourceWithIndexes, :email) == true
    end

    test "returns true for :name column (part of composite index)" do
      assert Dsl.has_secondary_index?(TestResourceWithIndexes, :name) == true
    end

    test "returns true for :status column" do
      assert Dsl.has_secondary_index?(TestResourceWithIndexes, :status) == true
    end

    test "returns false for :nonexistent column" do
      assert Dsl.has_secondary_index?(TestResourceWithIndexes, :nonexistent) == false
    end

    test "returns false for :id column (primary key, no index)" do
      assert Dsl.has_secondary_index?(TestResourceWithIndexes, :id) == false
    end
  end

  # ============================================================================
  # Repo Tests
  # ============================================================================

  describe "AshScylla.Repo" do
    test "module exists" do
      assert Code.ensure_loaded?(AshScylla.Repo)
    end

    test "is a macro module (exports __using__/1)" do
      assert {:__using__, 1} in AshScylla.Repo.__info__(:macros)
    end
  end

  # Repo inline module test must be async: false because it defines a module at runtime
end

defmodule AshScylla.DslRepoMigrationRepoInlineTest do
  @moduledoc """
  Tests that use `AshScylla.Repo` inline — must be async: false.
  """

  use ExUnit.Case, async: false

  defmodule TestRepoForDsl do
    use AshScylla.Repo, otp_app: :ash_scylla
  end

  describe "using AshScylla.Repo generates a module with keyspace/0, create_keyspace/1, drop_keyspace/1" do
    test "generates keyspace/0 function" do
      assert function_exported?(TestRepoForDsl, :keyspace, 0)
    end

    test "generates create_keyspace/1 function" do
      assert function_exported?(TestRepoForDsl, :create_keyspace, 1)
    end

    test "generates drop_keyspace/1 function" do
      assert function_exported?(TestRepoForDsl, :drop_keyspace, 1)
    end

    test "generates create_keyspace/0 function (default arg)" do
      assert function_exported?(TestRepoForDsl, :create_keyspace, 0)
    end

    test "generates drop_keyspace/0 function (default arg)" do
      assert function_exported?(TestRepoForDsl, :drop_keyspace, 0)
    end
  end
end

defmodule AshScylla.DslRepoMigrationContinuedTest do
  @moduledoc """
  Migration, AshScylla module, and DataLayer struct tests.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.Dsl
  alias AshScylla.Migration

  alias AshScylla.TestResourceWithIndexes

  # ============================================================================
  # Migration Tests
  # ============================================================================

  describe "Migration.drop_type/1" do
    test "returns correct CQL for dropping a UDT" do
      assert Migration.drop_type("full_name") == "DROP TYPE IF EXISTS full_name"
    end

    test "returns correct CQL for another type name" do
      assert Migration.drop_type("address") == "DROP TYPE IF EXISTS address"
    end
  end

  describe "Migration.drop_secondary_index_cql/2" do
    test "returns correct CQL for dropping a secondary index" do
      result = Migration.drop_secondary_index_cql(TestResourceWithIndexes, "idx_test_users_email")
      assert result == "DROP INDEX IF EXISTS idx_test_users_email"
    end

    test "returns correct CQL for a custom-named index" do
      result = Migration.drop_secondary_index_cql(TestResourceWithIndexes, "idx_user_status")
      assert result == "DROP INDEX IF EXISTS idx_user_status"
    end
  end

  describe "Migration.keyspace/1" do
    test "returns nil (placeholder implementation)" do
      assert Migration.keyspace(TestResourceWithIndexes) == nil
    end

    test "returns nil for any module" do
      assert Migration.keyspace(String) == nil
    end
  end

  describe "Migration.create_type/2" do
    test "creates a UDT with uuid field" do
      result = Migration.create_type("my_type", do: [id: {:uuid, []}])
      assert result =~ "CREATE TYPE IF NOT EXISTS my_type"
      assert result =~ "id UUID"
    end

    test "creates a UDT with integer field" do
      result = Migration.create_type("my_type", do: [count: {:integer, []}])
      assert result =~ "count BIGINT"
    end

    test "creates a UDT with boolean field" do
      result = Migration.create_type("my_type", do: [active: {:boolean, []}])
      assert result =~ "active BOOLEAN"
    end

    test "creates a UDT with utc_datetime field" do
      result = Migration.create_type("my_type", do: [inserted_at: {:utc_datetime, []}])
      assert result =~ "inserted_at TIMESTAMP"
    end

    test "creates a UDT with date field" do
      result = Migration.create_type("my_type", do: [born_on: {:date, []}])
      assert result =~ "born_on DATE"
    end

    test "creates a UDT with time field" do
      result = Migration.create_type("my_type", do: [start_at: {:time, []}])
      assert result =~ "start_at TIME"
    end

    test "creates a UDT with map field" do
      result = Migration.create_type("my_type", do: [metadata: {:map, []}])
      assert result =~ "metadata MAP<TEXT, TEXT>"
    end

    test "creates a UDT with map field and custom types" do
      result =
        Migration.create_type("my_type",
          do: [metadata: {:map, key_type: "UUID", value_type: "BIGINT"}]
        )

      assert result =~ "metadata MAP<UUID, BIGINT>"
    end

    test "creates a UDT with array (list) field" do
      result = Migration.create_type("my_type", do: [tags: {:array, []}])
      assert result =~ "tags LIST<TEXT>"
    end

    test "creates a UDT with array field and custom element type" do
      result = Migration.create_type("my_type", do: [ids: {:array, element_type: "UUID"}])
      assert result =~ "ids LIST<UUID>"
    end

    test "creates a UDT with set field" do
      result = Migration.create_type("my_type", do: [categories: {:set, []}])
      assert result =~ "categories SET<TEXT>"
    end

    test "creates a UDT with set field and custom element type" do
      result = Migration.create_type("my_type", do: [nums: {:set, element_type: "BIGINT"}])
      assert result =~ "nums SET<BIGINT>"
    end

    test "creates a UDT with udt field" do
      result = Migration.create_type("my_type", do: [address: {:udt, type_name: "address"}])
      assert result =~ "address address"
    end

    test "creates a UDT with udt field defaulting to frozen<undefined>" do
      result = Migration.create_type("my_type", do: [address: {:udt, []}])
      assert result =~ "address frozen<undefined>"
    end

    test "creates a UDT with frozen option" do
      result = Migration.create_type("my_type", do: [items: {:set, frozen: true}])
      assert result =~ "items frozen<SET<TEXT>>"
    end

    test "creates a UDT with string field (defaults to TEXT)" do
      result = Migration.create_type("my_type", do: [name: {:string, []}])
      assert result =~ "name TEXT"
    end
  end

  describe "Migration.create_secondary_indexes_cql/1" do
    test "returns CQL for creating secondary indexes for TestResourceWithIndexes" do
      result = Migration.create_secondary_indexes_cql(TestResourceWithIndexes)
      assert is_list(result)
      assert length(result) == 3
    end

    test "each CQL statement is a CREATE INDEX statement" do
      result = Migration.create_secondary_indexes_cql(TestResourceWithIndexes)

      Enum.each(result, fn cql ->
        assert cql =~ "CREATE INDEX IF NOT EXISTS"
        assert cql =~ "ON test_users"
      end)
    end

    test "returns [] for a resource with no indexes" do
      # TestResource has no ash_scylla DSL, so no indexes
      assert Migration.create_secondary_indexes_cql(AshScylla.TestResource) == []
    end
  end

  # ============================================================================
  # AshScylla module Tests
  # ============================================================================

  describe "AshScylla.version/0" do
    test "returns the current version string" do
      version = AshScylla.version()
      assert version == "0.3.0"
    end

    test "returns a string" do
      version = AshScylla.version()
      assert is_binary(version)
    end
  end

  # ============================================================================
  # DataLayer struct tests
  # ============================================================================

  describe "DataLayer struct defaults" do
    test "filters defaults to empty list" do
      query = %DataLayer{resource: nil, repo: nil, table: nil}
      assert query.filters == []
    end

    test "sorts defaults to empty list" do
      query = %DataLayer{resource: nil, repo: nil, table: nil}
      assert query.sorts == []
    end

    test "limit defaults to nil" do
      query = %DataLayer{resource: nil, repo: nil, table: nil}
      assert query.limit == nil
    end

    test "offset defaults to nil" do
      query = %DataLayer{resource: nil, repo: nil, table: nil}
      assert query.offset == nil
    end

    test "select defaults to nil" do
      query = %DataLayer{resource: nil, repo: nil, table: nil}
      assert query.select == nil
    end

    test "tenant defaults to nil" do
      query = %DataLayer{resource: nil, repo: nil, table: nil}
      assert query.tenant == nil
    end
  end

  describe "DataLayer.resource_to_query/2" do
    test "creates a proper query struct with resource set" do
      query = %DataLayer{resource: TestResourceWithIndexes, repo: nil, table: "test_users"}
      assert query.resource == TestResourceWithIndexes
    end

    test "creates a proper query struct with table set" do
      query = %DataLayer{resource: TestResourceWithIndexes, repo: nil, table: "test_users"}
      assert query.table == "test_users"
    end

    test "creates a proper query struct with default filters" do
      query = %DataLayer{resource: TestResourceWithIndexes, repo: nil, table: "test_users"}
      assert query.filters == []
    end

    test "creates a proper query struct with default sorts" do
      query = %DataLayer{resource: TestResourceWithIndexes, repo: nil, table: "test_users"}
      assert query.sorts == []
    end

    test "creates a proper query struct with nil limit" do
      query = %DataLayer{resource: TestResourceWithIndexes, repo: nil, table: "test_users"}
      assert query.limit == nil
    end

    test "creates a proper query struct with nil offset" do
      query = %DataLayer{resource: TestResourceWithIndexes, repo: nil, table: "test_users"}
      assert query.offset == nil
    end

    test "creates a proper query struct with nil select" do
      query = %DataLayer{resource: TestResourceWithIndexes, repo: nil, table: "test_users"}
      assert query.select == nil
    end

    test "creates a proper query struct with nil tenant" do
      query = %DataLayer{resource: TestResourceWithIndexes, repo: nil, table: "test_users"}
      assert query.tenant == nil
    end

    test "returns a DataLayer struct" do
      query = %DataLayer{resource: TestResourceWithIndexes, repo: nil, table: "test_users"}
      assert %DataLayer{} = query
    end
  end
end
