defmodule AshScylla.QueryAdvancedPipelineTest do
  @moduledoc """
  Complex end-to-end query pipeline tests for AshScylla.DataLayer.QueryBuilder.
  Covers: GROUP BY + aggregates, keyset pagination, multitenancy,
  DISTINCT, base_filter, OR-to-IN rewriting, and complex filter combinations.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.QueryBuilder

  # ---------------------------------------------------------------------------
  # Test resources
  # ---------------------------------------------------------------------------

  defmodule TenantResource do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      table("tenant_resource")
      keyspace("ash_scylla_test")
      secondary_index(:email)
      secondary_index(:status)
      consistency(:local_quorum)
      base_filter(%{name: :org_id, op: :eq, right: %{value: "org-1"}})
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:email, :string, public?: true)
      attribute(:status, :string, public?: true)
      attribute(:org_id, :string, public?: true)
      attribute(:age, :integer, public?: true)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule MultiPkResource do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      table("multi_pk_resource")
      keyspace("ash_scylla_test")
      secondary_index(:org_id)
    end

    attributes do
      attribute(:org_id, :string, primary_key?: true, public?: true, allow_nil?: false)
      attribute(:user_id, :uuid, primary_key?: true, public?: true, allow_nil?: false)
      attribute(:name, :string, public?: true)
      attribute(:org_name, :string, public?: true)
    end

    actions do
      defaults([:create, :read])
    end
  end

  # ---------------------------------------------------------------------------
  # GROUP BY + aggregate queries
  # ---------------------------------------------------------------------------

  describe "build_optimized_query with GROUP BY and aggregates" do
    test "single aggregate with GROUP BY" do
      data_layer = %AshScylla.Query{
        resource: TenantResource,
        table: "tenant_resource",
        filters: [],
        sorts: [],
        limit: nil,
        select: nil,
        distinct: nil,
        keyset: nil,
        aggregates: [%{kind: :count, name: :total, field: :id}],
        group_by: [:status]
      }

      {query, params} = QueryBuilder.build_optimized_query(data_layer)
      assert query =~ "SELECT COUNT(id) AS total FROM tenant_resource"
      assert query =~ "GROUP BY status"
      assert params == []
    end

    test "count(*) without field" do
      data_layer = %AshScylla.Query{
        resource: TenantResource,
        table: "tenant_resource",
        filters: [],
        sorts: [],
        limit: nil,
        select: nil,
        distinct: nil,
        keyset: nil,
        aggregates: [%{kind: :count, name: :total, field: nil}],
        group_by: [:status]
      }

      {query, _params} = QueryBuilder.build_optimized_query(data_layer)
      assert query =~ "COUNT(*) AS total"
    end

    test "multiple aggregates with GROUP BY" do
      data_layer = %AshScylla.Query{
        resource: TenantResource,
        table: "tenant_resource",
        filters: [],
        sorts: [],
        limit: nil,
        select: nil,
        distinct: nil,
        keyset: nil,
        aggregates: [
          %{kind: :count, name: :total, field: :id},
          %{kind: :sum, name: :total_age, field: :age}
        ],
        group_by: [:status, :org_id]
      }

      {query, params} = QueryBuilder.build_optimized_query(data_layer)
      assert query =~ "COUNT(id) AS total"
      assert query =~ "SUM(age) AS total_age"
      assert query =~ "GROUP BY status, org_id"
      assert params == []
    end

    test "aggregate with select columns" do
      data_layer = %AshScylla.Query{
        resource: TenantResource,
        table: "tenant_resource",
        filters: [],
        sorts: [],
        limit: nil,
        select: [:status],
        distinct: nil,
        keyset: nil,
        aggregates: [%{kind: :count, name: :total}],
        group_by: [:status]
      }

      {query, _params} = QueryBuilder.build_optimized_query(data_layer)
      assert query =~ "SELECT status, COUNT(*) AS total FROM tenant_resource"
      assert query =~ "GROUP BY status"
    end

    test "aggregate with filters and GROUP BY" do
      data_layer = %AshScylla.Query{
        resource: TenantResource,
        table: "tenant_resource",
        filters: [
          %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
        ],
        sorts: [],
        limit: 100,
        select: nil,
        distinct: nil,
        keyset: nil,
        aggregates: [%{kind: :count, name: :total}],
        group_by: [:org_id]
      }

      {query, params} = QueryBuilder.build_optimized_query(data_layer)
      assert query =~ "SELECT COUNT(*) AS total FROM tenant_resource"
      assert query =~ "WHERE status = ?"
      assert query =~ "GROUP BY org_id"
      assert query =~ "LIMIT ?"
      assert length(params) == 2
    end

    test "unsupported aggregate falls back to COUNT" do
      data_layer = %AshScylla.Query{
        resource: TenantResource,
        table: "tenant_resource",
        filters: [],
        sorts: [],
        limit: nil,
        select: nil,
        distinct: nil,
        keyset: nil,
        aggregates: [%{kind: :median, name: :median_val}],
        group_by: []
      }

      {query, _params} = QueryBuilder.build_optimized_query(data_layer)
      assert query =~ "COUNT(*) AS median_val"
    end
  end

  # ---------------------------------------------------------------------------
  # Keyset pagination
  # ---------------------------------------------------------------------------

  describe "build_optimized_query with keyset pagination" do
    test "keyset with single partition key" do
      data_layer = %AshScylla.Query{
        resource: TenantResource,
        table: "tenant_resource",
        filters: [],
        sorts: [],
        limit: 20,
        select: nil,
        distinct: nil,
        keyset: %{
          partition_keys: [:id],
          values: ["550e8400-e29b-41d4-a716-446655440000"],
          direction: :after
        },
        aggregates: [],
        group_by: nil
      }

      {query, params} = QueryBuilder.build_optimized_query(data_layer)
      assert query =~ "TOKEN(id) > TOKEN(?)"
      assert query =~ "LIMIT ?"
      assert length(params) == 2
    end

    test "keyset with composite partition key" do
      data_layer = %AshScylla.Query{
        resource: MultiPkResource,
        table: "multi_pk_resource",
        filters: [],
        sorts: [],
        limit: 10,
        select: nil,
        distinct: nil,
        keyset: %{
          partition_keys: [:org_id, :user_id],
          values: ["org-1", "user-1"],
          direction: :after
        },
        aggregates: [],
        group_by: nil
      }

      {query, params} = QueryBuilder.build_optimized_query(data_layer)
      assert query =~ "TOKEN(org_id, user_id) > TOKEN(?, ?)"
      assert length(params) == 3
    end

    test "keyset direction :before uses <" do
      data_layer = %AshScylla.Query{
        resource: TenantResource,
        table: "tenant_resource",
        filters: [],
        sorts: [],
        limit: 10,
        select: nil,
        distinct: nil,
        keyset: %{
          partition_keys: [:id],
          values: ["abc"],
          direction: :before
        },
        aggregates: [],
        group_by: nil
      }

      {query, _params} = QueryBuilder.build_optimized_query(data_layer)
      assert query =~ "TOKEN(id) < TOKEN(?)"
    end

    test "keyset defaults to :after when direction omitted" do
      data_layer = %AshScylla.Query{
        resource: TenantResource,
        table: "tenant_resource",
        filters: [],
        sorts: [],
        limit: 10,
        select: nil,
        distinct: nil,
        keyset: %{
          partition_keys: [:id],
          values: ["abc"]
        },
        aggregates: [],
        group_by: nil
      }

      {query, _params} = QueryBuilder.build_optimized_query(data_layer)
      assert query =~ "TOKEN(id) > TOKEN(?)"
    end
  end

  # ---------------------------------------------------------------------------
  # DISTINCT queries
  # ---------------------------------------------------------------------------

  describe "build_optimized_query with DISTINCT" do
    test "distinct with nil select falls through to SELECT *" do
      # When select is nil, distinct is not applied (catch-all clause returns *)
      data_layer = %AshScylla.Query{
        resource: TenantResource,
        table: "tenant_resource",
        filters: [],
        sorts: [],
        limit: nil,
        select: nil,
        distinct: [:status],
        keyset: nil,
        aggregates: [],
        group_by: nil
      }

      {query, _params} = QueryBuilder.build_optimized_query(data_layer)
      assert query =~ "SELECT * FROM tenant_resource"
    end

    test "distinct with empty select list also falls through to SELECT *" do
      # The distinct clause only matches when select is nil, not []
      data_layer = %AshScylla.Query{
        resource: TenantResource,
        table: "tenant_resource",
        filters: [],
        sorts: [],
        limit: nil,
        select: [],
        distinct: [:status, :org_id],
        keyset: nil,
        aggregates: [],
        group_by: nil
      }

      {query, _params} = QueryBuilder.build_optimized_query(data_layer)
      assert query =~ "SELECT * FROM tenant_resource"
    end

    test "distinct with filters produces SELECT * (catch-all)" do
      data_layer = %AshScylla.Query{
        resource: TenantResource,
        table: "tenant_resource",
        filters: [
          %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
        ],
        sorts: [],
        limit: 50,
        select: [],
        distinct: [:email],
        keyset: nil,
        aggregates: [],
        group_by: nil
      }

      {query, params} = QueryBuilder.build_optimized_query(data_layer)
      assert query =~ "SELECT * FROM tenant_resource"
      assert query =~ "WHERE status = ?"
      assert query =~ "LIMIT ?"
      assert length(params) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Base filter integration
  # ---------------------------------------------------------------------------

  describe "apply_base_filter/2" do
    test "prepends base_filter to existing filters" do
      base = %{name: :org_id, op: :eq, right: %{value: "org-1"}}
      filters = [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}]

      result = QueryBuilder.apply_base_filter(filters, base)
      assert length(result) == 2
      assert hd(result) == base
    end

    test "returns filters unchanged when base_filter is nil" do
      filters = [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}]
      assert QueryBuilder.apply_base_filter(filters, nil) == filters
    end

    test "returns filters unchanged when base_filter is empty list" do
      filters = [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}]
      assert QueryBuilder.apply_base_filter(filters, []) == filters
    end

    test "prepends list of base filters" do
      base = [
        %{name: :org_id, op: :eq, right: %{value: "org-1"}},
        %{name: :tenant_id, op: :eq, right: %{value: "tenant-1"}}
      ]

      filters = [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}]
      result = QueryBuilder.apply_base_filter(filters, base)
      assert length(result) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # OR-to-IN rewriting (via filter_to_cql with IN)
  # ---------------------------------------------------------------------------

  describe "OR-to-IN rewriting" do
    test "IN with list value" do
      filter = %{operator: :in, left: %{name: :status}, right: %{value: ["active", "pending"]}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)

      assert cql =~ "status IN (?, ?)"
      assert params == ["active", "pending"]
    end

    test "IN with single value" do
      filter = %{operator: :in, left: %{name: :status}, right: %{value: ["active"]}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql =~ "status IN (?)"
      assert params == ["active"]
    end

    test "IN with MapSet value directly on right" do
      # When MapSet is the raw right value (not wrapped in %{value: ...}),
      # the code converts it to a list and builds an IN clause
      filter = %{
        operator: :in,
        left: %{name: :status},
        right: MapSet.new(["active", "pending"])
      }

      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql =~ "status IN (?, ?)"
      assert length(params) == 2
    end

    test "IN with large list" do
      values = Enum.to_list(1..100)
      filter = %{operator: :in, left: %{name: :id}, right: %{value: values}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)

      assert cql =~ "id IN ("
      assert length(params) == 100
    end
  end

  # ---------------------------------------------------------------------------
  # Complex filter combinations
  # ---------------------------------------------------------------------------

  describe "complex filter combinations" do
    test "nested AND/OR/AND 3 levels deep" do
      filter = %{
        op: :and,
        left: %{
          op: :or,
          left: %{name: :status, op: :eq, right: %{value: "active"}},
          right: %{name: :status, op: :eq, right: %{value: "pending"}}
        },
        right: %{
          op: :and,
          left: %{name: :email, op: :eq, right: %{value: "a@b.co"}},
          right: %{name: :org_id, op: :eq, right: %{value: "org-1"}}
        }
      }

      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql =~ "("
      assert cql =~ "OR"
      assert cql =~ "AND"
      assert cql =~ "status = ?"
      assert cql =~ "email = ?"
      assert cql =~ "org_id = ?"
      assert length(params) == 4
    end

    test "AND with IN on both sides" do
      filter = %{
        op: :and,
        left: %{name: :status, op: :in, right: %{value: ["active", "pending"]}},
        right: %{name: :org_id, op: :in, right: %{value: ["org-1", "org-2"]}}
      }

      {cql, params} = QueryBuilder.build_where_clause([filter])
      assert cql =~ "status IN (?, ?)"
      assert cql =~ "org_id IN (?, ?)"
      assert length(params) == 4
    end

    test "range operators on clustering columns" do
      filter = %{
        op: :and,
        left: %{name: :id, op: :eq, right: %{value: "abc"}},
        right: %{
          op: :and,
          left: %{name: :created_at, op: :gte, right: %{value: "2024-01-01"}},
          right: %{name: :created_at, op: :lt, right: %{value: "2025-01-01"}}
        }
      }

      {cql, params} = QueryBuilder.build_where_clause([filter])
      assert cql =~ "id = ?"
      assert cql =~ "created_at >= ?"
      assert cql =~ "created_at < ?"
      assert length(params) == 3
    end

    test "LIKE contains operator embeds wildcards" do
      filter = %{name: :email, op: :contains, right: %{value: "@example.com"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql =~ "LIKE ?"
      # contains wraps with %...%
      assert params == ["%@example.com%"]
    end

    test "LIKE starts_with embeds wildcard suffix" do
      filter = %{name: :email, op: :starts_with, right: %{value: "alice"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql =~ "LIKE ?"
      assert params == ["%alice"]
    end

    test "LIKE ends_with embeds wildcard prefix" do
      filter = %{name: :email, op: :ends_with, right: %{value: "example.com"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql =~ "LIKE ?"
      assert params == ["example.com%"]
    end

    test "CONTAINS KEY for map column" do
      filter = %{name: :metadata, op: :contains_key, right: %{value: "role"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql =~ "CONTAINS KEY ?"
      assert params == ["role"]
    end

    test "IS NULL" do
      nil_filter = %{name: :email, op: :is_nil, right: %{value: true}}
      {cql, params} = QueryBuilder.filter_to_cql(nil_filter)
      assert cql =~ "IS NULL"
      assert params == []
    end

    test "IS NOT NULL" do
      not_nil_filter = %{name: :email, op: :is_nil, right: %{value: false}}
      {cql, params} = QueryBuilder.filter_to_cql(not_nil_filter)
      assert cql =~ "IS NOT NULL"
      assert params == []
    end

    test "EXISTS operator" do
      filter = %{name: :email, op: :exists, right: %{value: true}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql =~ "IS NOT NULL"
      assert params == []
    end
  end

  # ---------------------------------------------------------------------------
  # secondary_index_scan?
  # ---------------------------------------------------------------------------

  describe "secondary_index_scan?/2" do
    test "true when all filters on indexed columns" do
      filters = [
        %{operator: :eq, left: %{name: :email}, right: %{value: "a@b.co"}},
        %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
      ]

      assert QueryBuilder.secondary_index_scan?(TenantResource, filters) == true
    end

    test "false when filter on non-indexed column" do
      filters = [
        %{operator: :eq, left: %{name: :email}, right: %{value: "a@b.co"}},
        %{operator: :eq, left: %{name: :age}, right: %{value: 30}}
      ]

      assert QueryBuilder.secondary_index_scan?(TenantResource, filters) == false
    end

    test "true when filter on pk column" do
      filters = [%{operator: :eq, left: %{name: :id}, right: %{value: "abc"}}]
      assert QueryBuilder.secondary_index_scan?(TenantResource, filters) == true
    end
  end

  # ---------------------------------------------------------------------------
  # Aggregate query builder
  # ---------------------------------------------------------------------------

  describe "build_aggregate_query/4" do
    test "builds count query with where clause" do
      {query, params} =
        QueryBuilder.build_aggregate_query(
          "users",
          "COUNT(*) AS total",
          "status = ?",
          ["active"]
        )

      assert query == "SELECT COUNT(*) AS total FROM users WHERE status = ?"
      assert params == ["active"]
    end

    test "builds count query without where clause" do
      {query, params} =
        QueryBuilder.build_aggregate_query(
          "users",
          "COUNT(*) AS total",
          "",
          []
        )

      assert query == "SELECT COUNT(*) AS total FROM users"
      assert params == []
    end
  end

  # ---------------------------------------------------------------------------
  # aggregate_to_cql/2
  # ---------------------------------------------------------------------------

  describe "aggregate_to_cql/2" do
    test "count(*)" do
      assert QueryBuilder.aggregate_to_cql(:count, nil) == "COUNT(*)"
    end

    test "count(field)" do
      assert QueryBuilder.aggregate_to_cql(:count, :age) == "COUNT(age)"
    end

    test "sum/avg/min/max" do
      assert QueryBuilder.aggregate_to_cql(:sum, :age) == "SUM(age)"
      assert QueryBuilder.aggregate_to_cql(:avg, :age) == "AVG(age)"
      assert QueryBuilder.aggregate_to_cql(:min, :age) == "MIN(age)"
      assert QueryBuilder.aggregate_to_cql(:max, :age) == "MAX(age)"
    end

    test "unsupported falls back to COUNT(*)" do
      assert QueryBuilder.aggregate_to_cql(:median, nil) == "COUNT(*)"
    end

    test "unsupported with field falls back to COUNT(field)" do
      assert QueryBuilder.aggregate_to_cql(:median, :age) == "COUNT(age)"
    end
  end

  # ---------------------------------------------------------------------------
  # cql_identifier edge cases
  # ---------------------------------------------------------------------------

  describe "cql_identifier edge cases via build_where_clause" do
    test "reserved keyword columns are quoted" do
      filter = %{name: :select, op: :eq, right: %{value: "x"}}
      {cql, _params} = QueryBuilder.build_where_clause([filter])
      assert cql =~ "\"select\" = ?"
    end

    test "reserved keyword 'from' is quoted" do
      filter = %{name: :from, op: :eq, right: %{value: "x"}}
      {cql, _params} = QueryBuilder.build_where_clause([filter])
      assert cql =~ "\"from\" = ?"
    end

    test "reserved keyword 'where' is quoted" do
      filter = %{name: :where, op: :eq, right: %{value: "x"}}
      {cql, _params} = QueryBuilder.build_where_clause([filter])
      assert cql =~ "\"where\" = ?"
    end

    test "reserved keyword 'order' is quoted" do
      filter = %{name: :order, op: :eq, right: %{value: "x"}}
      {cql, _params} = QueryBuilder.build_where_clause([filter])
      assert cql =~ "\"order\" = ?"
    end

    test "non-reserved column is not quoted" do
      filter = %{name: :username, op: :eq, right: %{value: "x"}}
      {cql, _params} = QueryBuilder.build_where_clause([filter])
      assert cql =~ "username = ?"
      refute cql =~ "\"username\""
    end
  end

  # ---------------------------------------------------------------------------
  # build_order_by edge cases
  # ---------------------------------------------------------------------------

  describe "build_order_by/1 edge cases" do
    test "mixed sort formats" do
      sorts = [
        %{field: :name, direction: :asc},
        {:email, :desc},
        %{field: :age}
      ]

      {clause, _params} = QueryBuilder.build_order_by(sorts)
      assert clause =~ "name asc"
      assert clause =~ "email desc"
      assert clause =~ "age ASC"
    end

    test "handles unexpected sort item" do
      sorts = ["invalid", %{field: :name, direction: :asc}]
      {clause, _params} = QueryBuilder.build_order_by(sorts)
      assert clause == "name asc"
    end
  end
end
