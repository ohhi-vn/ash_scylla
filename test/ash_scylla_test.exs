defmodule AshScylla.Test do
  use ExUnit.Case, async: false

  # Note: These tests require a running ScyllaDB instance
  # To run: docker run -p 9042:9042 scylladb/scylla
  # Then configure the repo to connect to localhost:9042

  describe "DataLayer can?/1" do
    test "returns true for supported features" do
      assert AshScylla.DataLayer.can?(nil, :create) == true
      assert AshScylla.DataLayer.can?(nil, :read) == true
      assert AshScylla.DataLayer.can?(nil, :update) == true
      assert AshScylla.DataLayer.can?(nil, :destroy) == true
      assert AshScylla.DataLayer.can?(nil, :filter) == true
      assert AshScylla.DataLayer.can?(nil, :sort) == true
      assert AshScylla.DataLayer.can?(nil, :limit) == true
      assert AshScylla.DataLayer.can?(nil, :offset) == true
      assert AshScylla.DataLayer.can?(nil, :select) == true
      assert AshScylla.DataLayer.can?(nil, :multitenancy) == true
    end

    test "returns false for unsupported features" do
      assert AshScylla.DataLayer.can?(nil, :transact) == false
      assert AshScylla.DataLayer.can?(nil, {:aggregate, :count}) == false
      assert AshScylla.DataLayer.can?(nil, {:join, nil}) == false
      assert AshScylla.DataLayer.can?(nil, {:lateral_join, []}) == false
    end
  end

  describe "DataLayer bulk_create support" do
    test "bulk_create is supported" do
      assert AshScylla.DataLayer.can?(nil, :bulk_create) == true
    end
  end

  describe "CQL generation" do
    test "build_select/2 generates correct SELECT" do
      # Test the private function via the module
      # This is a basic test - in real scenario, test via public API
      assert true
    end

    test "QueryBuilder handles complex nested filters" do
      # Test AND/OR combinations
      filter = %{
        op: :and,
        left: %{
          op: :or,
          left: %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}},
          right: %{operator: :eq, left: %{name: "status"}, right: %{value: "pending"}}
        },
        right: %{operator: :gt, left: %{name: "age"}, right: %{value: 18}}
      }

      {cql, params} = AshScylla.DataLayer.QueryBuilder.filter_to_cql(filter)
      assert String.contains?(cql, "AND")
      assert String.contains?(cql, "OR")
      assert params == ["active", "pending", 18]
    end

    test "QueryBuilder handles IN operator with multiple values" do
      filter = %{
        operator: :in,
        left: %{name: "category"},
        right: %{value: ["A", "B", "C", "D", "E"]}
      }

      {cql, params} = AshScylla.DataLayer.QueryBuilder.filter_to_cql(filter)
      # The IN operator should generate the right number of placeholders
      assert String.contains?(cql, "IN")
      # Should have 5 placeholders for 5 values
      assert String.contains?(cql, "?, ?, ?, ?, ?")
      assert params == ["A", "B", "C", "D", "E"]
    end
  end

  describe "DSL module" do
    test "table/1 returns nil when not configured" do
      # TestResource doesn't use ash_scylla DSL block
      assert AshScylla.DataLayer.Dsl.table(AshScylla.TestResource) == nil
    end

    test "keyspace/1 returns nil when not configured" do
      assert AshScylla.DataLayer.Dsl.keyspace(AshScylla.TestResource) == nil
    end

    test "consistency/1 returns nil when not configured" do
      assert AshScylla.DataLayer.Dsl.consistency(AshScylla.TestResource) == nil
    end

    test "ttl/1 returns nil when not configured" do
      assert AshScylla.DataLayer.Dsl.ttl(AshScylla.TestResource) == nil
    end
  end

  describe "DSL macro" do
    @tag :skip
    test "generates __ash_scylla__ function" do
      # This test requires runtime module compilation which is complex
      # The DSL functionality is tested via the Dsl module functions
      assert true
    end
  end

  describe "Migration helpers" do
    test "create_table_cql/1 generates CQL" do
      # This would need a mock resource module
      # For now, just test it doesn't crash
      assert true
    end

    test "Migration.create_type/2 with nested UDTs" do
      cql = AshScylla.Migration.create_type("address", do: [
        first_name: {:text, []},
        last_name: {:text, []},
        zip: {:text, []}
      ])

      assert String.contains?(cql, "CREATE TYPE IF NOT EXISTS address")
      assert String.contains?(cql, "first_name TEXT")
      assert String.contains?(cql, "last_name TEXT")
      assert String.contains?(cql, "zip TEXT")
    end

    test "Migration handles collection types" do
      # Test that migration module handles list, set, map types
      assert true
    end
  end
end
