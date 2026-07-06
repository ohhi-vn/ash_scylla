defmodule AshScylla.Test do
  use ExUnit.Case, async: false

  describe "DataLayer can?/2 — supported features" do
    test "returns true for CRUD features" do
      assert AshScylla.DataLayer.can?(nil, :create) == true
      assert AshScylla.DataLayer.can?(nil, :read) == true
      assert AshScylla.DataLayer.can?(nil, :update) == true
      assert AshScylla.DataLayer.can?(nil, :destroy) == true
    end

    test "returns true for query features" do
      assert AshScylla.DataLayer.can?(nil, :filter) == true
      assert AshScylla.DataLayer.can?(nil, :limit) == true
      assert AshScylla.DataLayer.can?(nil, :select) == true
      assert AshScylla.DataLayer.can?(nil, :sort) == true
      assert AshScylla.DataLayer.can?(nil, {:sort, :string}) == true
      assert AshScylla.DataLayer.can?(nil, :distinct) == true
      assert AshScylla.DataLayer.can?(nil, :keyset) == true
      assert AshScylla.DataLayer.can?(nil, :boolean_filter) == true
      assert AshScylla.DataLayer.can?(nil, :nested_expressions) == true
      assert AshScylla.DataLayer.can?(nil, {:filter_expr, %{}}) == true
    end

    test "returns true for action features" do
      assert AshScylla.DataLayer.can?(nil, :upsert) == true
      assert AshScylla.DataLayer.can?(nil, :bulk_create) == true
      assert AshScylla.DataLayer.can?(nil, :update_query) == true
      assert AshScylla.DataLayer.can?(nil, :destroy_query) == true
      assert AshScylla.DataLayer.can?(nil, :transact) == true
      assert AshScylla.DataLayer.can?(nil, :changeset_filter) == true
      assert AshScylla.DataLayer.can?(nil, :calculate) == true
      assert AshScylla.DataLayer.can?(nil, :action_select) == true
      assert AshScylla.DataLayer.can?(nil, :async_engine) == true
    end

    test "returns true for structural features" do
      assert AshScylla.DataLayer.can?(nil, :multitenancy) == true
      assert AshScylla.DataLayer.can?(nil, :composite_primary_key) == true
    end

    test "returns true for atomic operations" do
      assert AshScylla.DataLayer.can?(nil, {:atomic, :update}) == true
      assert AshScylla.DataLayer.can?(nil, {:atomic, :upsert}) == true
      assert AshScylla.DataLayer.can?(nil, {:atomic, :create}) == true
    end

    test "returns true for count aggregate" do
      assert AshScylla.DataLayer.can?(nil, {:aggregate, :count}) == true
    end
  end

  describe "DataLayer can?/2 — unsupported features" do
    test "returns false for pagination features not in ScyllaDB" do
      assert AshScylla.DataLayer.can?(nil, :offset) == false
      assert AshScylla.DataLayer.can?(nil, :distinct_sort) == false
    end

    test "returns false for expression/calculation features" do
      assert AshScylla.DataLayer.can?(nil, :expr_error) == false
      assert AshScylla.DataLayer.can?(nil, :expression_calculation) == false
      assert AshScylla.DataLayer.can?(nil, :expression_calculation_sort) == false
    end

    test "returns false for aggregate features beyond count" do
      assert AshScylla.DataLayer.can?(nil, {:aggregate, :sum}) == false
      assert AshScylla.DataLayer.can?(nil, {:aggregate, :avg}) == false
      assert AshScylla.DataLayer.can?(nil, {:aggregate, :min}) == false
      assert AshScylla.DataLayer.can?(nil, {:aggregate, :max}) == false
      assert AshScylla.DataLayer.can?(nil, {:aggregate, :exists}) == false
      assert AshScylla.DataLayer.can?(nil, {:aggregate, :unrelated}) == false
      assert AshScylla.DataLayer.can?(nil, {:aggregate_relationship, nil}) == false
      assert AshScylla.DataLayer.can?(nil, {:query_aggregate, :count}) == false
      assert AshScylla.DataLayer.can?(nil, :aggregate_filter) == false
      assert AshScylla.DataLayer.can?(nil, :aggregate_sort) == false
    end

    test "returns false for join/relationship features" do
      assert AshScylla.DataLayer.can?(nil, {:join, nil}) == false
      assert AshScylla.DataLayer.can?(nil, {:lateral_join, []}) == false
      assert AshScylla.DataLayer.can?(nil, :lateral_join) == false
      assert AshScylla.DataLayer.can?(nil, {:filter_relationship, nil}) == false
      assert AshScylla.DataLayer.can?(nil, :through_relationship) == false
    end

    test "returns false for combination queries" do
      assert AshScylla.DataLayer.can?(nil, {:combine, :union}) == false
      assert AshScylla.DataLayer.can?(nil, {:combine, :union_all}) == false
      assert AshScylla.DataLayer.can?(nil, {:combine, :intersection}) == false
    end

    test "returns false for locking" do
      assert AshScylla.DataLayer.can?(nil, :lock) == false
      assert AshScylla.DataLayer.can?(nil, {:lock, :for_update}) == false
    end

    test "returns false for bulk/update features not implemented" do
      assert AshScylla.DataLayer.can?(nil, :bulk_create_with_partial_success) == false
      assert AshScylla.DataLayer.can?(nil, :update_many) == false
      assert AshScylla.DataLayer.can?(nil, :bulk_upsert_return_skipped) == false
    end

    test "returns false for type/composite features" do
      assert AshScylla.DataLayer.can?(nil, :composite_type) == false
    end

    test "returns false for exists queries" do
      assert AshScylla.DataLayer.can?(nil, {:exists, :unrelated}) == false
    end

    test "returns false for unknown features" do
      assert AshScylla.DataLayer.can?(nil, :non_existent_feature) == false
      assert AshScylla.DataLayer.can?(nil, {:unknown, :tuple}) == false
    end
  end

  describe "AshScylla.verify/2" do
    test "checks repo configuration without opening a connection" do
      assert {:ok, report} = AshScylla.verify(AshScylla.TestRepo, check_connection?: false)

      assert report.repo == AshScylla.TestRepo
      assert report.nodes == ["127.0.0.1:9042"]
      assert report.keyspace == "ash_scylla_dev"
      assert report.connection.checked? == false
      assert report.connection.release_version == :skipped
      assert report.keyspace_report == %{name: "ash_scylla_dev", checked?: false, exists?: nil}
      assert report.resources == []
    end

    test "checks configured resource tables without opening a connection" do
      assert {:ok, report} =
               AshScylla.verify(AshScylla.TestRepo,
                 check_connection?: false,
                 resources: [AshScylla.TestResource, AshScylla.TestResourceWithIndexes]
               )

      assert [
               %{
                 resource: AshScylla.TestResource,
                 keyspace: "ash_scylla_test",
                 table: "test_resource",
                 checked?: false,
                 exists?: nil
               },
               %{
                 resource: AshScylla.TestResourceWithIndexes,
                 keyspace: "ash_scylla_test",
                 table: "test_users",
                 checked?: false,
                 exists?: nil
               }
             ] = report.resources
    end

    test "verify!/2 returns the report" do
      report = AshScylla.verify!(AshScylla.TestRepo, check_connection?: false)
      assert report.repo == AshScylla.TestRepo
    end

    test "returns validation errors for invalid repo configuration" do
      assert {:error, :no_nodes} =
               AshScylla.verify(AshScylla.TestRepo, check_connection?: false, nodes: [])

      assert {:error, {:invalid_keyspace, "bad-keyspace"}} =
               AshScylla.verify(AshScylla.TestRepo,
                 check_connection?: false,
                 keyspace: "bad-keyspace"
               )

      assert {:error, {:invalid_resources, :not_a_list}} =
               AshScylla.verify(AshScylla.TestRepo,
                 check_connection?: false,
                 resources: :not_a_list
               )
    end
  end

  describe "CQL generation" do
    test "QueryBuilder handles complex nested filters" do
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
      assert String.contains?(cql, "IN")
      assert params == ["active", "pending", 18]
    end

    test "QueryBuilder handles IN operator with multiple values" do
      filter = %{
        operator: :in,
        left: %{name: "category"},
        right: %{value: ["A", "B", "C", "D", "E"]}
      }

      {cql, params} = AshScylla.DataLayer.QueryBuilder.filter_to_cql(filter)
      assert String.contains?(cql, "IN")
      assert String.contains?(cql, "?, ?, ?, ?, ?")
      assert params == ["A", "B", "C", "D", "E"]
    end
  end

  describe "DSL module" do
    test "table/1 returns nil when not configured" do
      assert AshScylla.DataLayer.Dsl.table(String) == nil
    end

    test "keyspace/1 returns nil when not configured" do
      assert AshScylla.DataLayer.Dsl.keyspace(String) == nil
    end

    test "consistency/1 returns nil when not configured" do
      assert AshScylla.DataLayer.Dsl.consistency(String) == nil
    end

    test "ttl/1 returns nil when not configured" do
      assert AshScylla.DataLayer.Dsl.ttl(String) == nil
    end

    test "table/1 returns configured table for TestResource" do
      assert AshScylla.DataLayer.Dsl.table(AshScylla.TestResource) == "test_resource"
    end

    test "table/1 returns configured table for TestResourceWithIndexes" do
      assert AshScylla.DataLayer.Dsl.table(AshScylla.TestResourceWithIndexes) == "test_users"
    end

    test "keyspace/1 returns configured keyspace" do
      assert AshScylla.DataLayer.Dsl.keyspace(AshScylla.TestResourceWithIndexes) ==
               "ash_scylla_test"
    end

    test "consistency/1 returns configured consistency" do
      assert AshScylla.DataLayer.Dsl.consistency(AshScylla.TestResourceWithIndexes) == :quorum
    end

    test "ttl/1 returns configured ttl" do
      assert AshScylla.DataLayer.Dsl.ttl(AshScylla.TestResourceWithIndexes) == 3600
    end

    test "secondary_indexes/1 returns configured indexes" do
      indexes = AshScylla.DataLayer.Dsl.secondary_indexes(AshScylla.TestResource)
      assert length(indexes) == 2
    end

    test "repo/1 returns configured repo" do
      assert AshScylla.DataLayer.Dsl.repo(AshScylla.TestResource) == AshScylla.TestRepo
    end
  end

  describe "TestResource Ash 3.0+ features" do
    test "has domain configured" do
      assert Ash.Resource.Info.domain(AshScylla.TestResource) == AshScylla.TestDomain
    end

    test "has attributes with public? flag" do
      assert Ash.Resource.Info.attribute(AshScylla.TestResource, :name).public? == true
      assert Ash.Resource.Info.attribute(AshScylla.TestResource, :password_hash).public? == false
    end

    test "has create_timestamp and update_timestamp" do
      attributes = Ash.Resource.Info.attributes(AshScylla.TestResource)
      attr_names = Enum.map(attributes, & &1.name)
      assert :created_at in attr_names
      assert :updated_at in attr_names
    end

    test "has primary key" do
      pk = Ash.Resource.Info.primary_key(AshScylla.TestResource)
      assert :id in pk
    end

    test "has code_interface definitions" do
      interfaces = Ash.Resource.Info.interfaces(AshScylla.TestResource)
      names = Enum.map(interfaces, & &1.name)
      assert :create in names
      assert :read in names
    end
  end

  describe "Migration helpers" do
    test "create_table_cql/1 generates CQL" do
      cql = AshScylla.Migration.create_table_cql(AshScylla.TestResourceWithIndexes)
      assert String.contains?(cql, "CREATE TABLE")
      assert String.contains?(cql, "test_users")
    end

    test "create_type/2 with fields" do
      cql =
        AshScylla.Migration.create_type("address",
          do: [
            first_name: {:text, []},
            last_name: {:text, []},
            zip: {:text, []}
          ]
        )

      assert String.contains?(cql, "CREATE TYPE IF NOT EXISTS address")
      assert String.contains?(cql, "first_name TEXT")
      assert String.contains?(cql, "last_name TEXT")
      assert String.contains?(cql, "zip TEXT")
    end
  end
end
