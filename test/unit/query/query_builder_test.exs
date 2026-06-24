defmodule AshScylla.DataLayer.QueryBuilderTest do
  @moduledoc """
  Comprehensive tests for AshScylla.DataLayer.QueryBuilder and
  AshScylla.DataLayer.Pagination modules.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.QueryBuilder

  # ============================================================================
  # build_optimized_query/1
  # ============================================================================

  describe "build_optimized_query/1" do
    test "simple SELECT * with no filters, sorts, or limit" do
      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql == "SELECT * FROM users"
      assert params == []
    end

    test "SELECT with specific columns" do
      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [:name, :email],
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)
      assert cql == "SELECT name, email FROM users"
    end

    test "SELECT with single equality filter" do
      filter = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql == "SELECT * FROM users WHERE status = ?"
      assert params == ["active"]
    end

    test "SELECT with multiple filters joined by AND" do
      f1 = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
      f2 = %{operator: :gt, left: %{name: "age"}, right: %{value: 18}}

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [f1, f2],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "WHERE")
      assert String.contains?(cql, "AND")
    end

    test "SELECT with ORDER BY" do
      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [],
        sorts: [{:name, :asc}],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "ORDER BY name asc")
    end

    test "SELECT with LIMIT" do
      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [],
        sorts: [],
        limit: 10,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "LIMIT ?")
      assert {"int", 10} in params
    end

    test "combined: filter + sort + limit" do
      filter = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [{:created_at, :desc}],
        limit: 25,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "WHERE")
      assert String.contains?(cql, "ORDER BY created_at desc")
      assert String.contains?(cql, "LIMIT ?")
      assert "active" in params
      assert {"int", 25} in params
    end

    test "IN operator filter" do
      filter = %{operator: :in, left: %{name: "status"}, right: %{value: ["active", "pending"]}}

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "IN")
      assert params == ["active", "pending"]
    end

    test "nested AND produces flat chain without extra parentheses" do
      filter = %{
        op: :and,
        left: %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}},
        right: %{operator: :gt, left: %{name: "age"}, right: %{value: 18}}
      }

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql == "SELECT * FROM users WHERE status = ? AND age > ?"
      assert params == ["active", 18]
    end

    test "chained AND filters should NOT produce double parentheses" do
      # This replicates how Ash nests the `get_user_games_by_date_range` pattern:
      #   ((user_id = ?) AND (started_at >= ?)) AND (started_at <= ?)
      # which previously produced invalid CQL: "line 1:89 : Missing ')'"
      inner = %{
        op: :and,
        left: %{operator: :eq, left: %{name: "user_id"}, right: %{value: "u1"}},
        right: %{operator: :gte, left: %{name: "started_at"}, right: %{value: "2026-01-01"}}
      }

      outer = %{
        op: :and,
        left: inner,
        right: %{operator: :lte, left: %{name: "started_at"}, right: %{value: "2026-12-31"}}
      }

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "game_members",
        filters: [outer],
        sorts: [{:started_at, :desc}],
        limit: nil,
        offset: nil,
        select: [:id, :started_at, :user_id, :game_id, :is_admin],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)

      # Must not contain double-parens — CQL rejects ((...))
      refute String.contains?(cql, "(("), "CQL must not contain double opening parens"
      refute String.contains?(cql, "))"), "CQL must not contain double closing parens"

      # Must produce valid flat AND chain
      assert cql ==
               "SELECT id, started_at, user_id, game_id, is_admin FROM game_members WHERE user_id = ? AND started_at >= ? AND started_at <= ? ORDER BY started_at desc"

      assert params == ["u1", "2026-01-01", "2026-12-31"]
    end
  end

  describe "build_optimized_query/1 with secondary index scan" do
    defmodule IndexedMember do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes), do: [%{columns: [:user_id, :status]}]
    end

    defmodule NonIndexedMember do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes), do: []
    end

    test "ORDER BY is dropped when scanning via secondary index" do
      filter = %{operator: :eq, left: %{name: :user_id}, right: %{value: "u1"}}

      query = %DataLayer{
        resource: IndexedMember,
        repo: nil,
        table: "game_members",
        filters: [filter],
        sorts: [{:started_at, :desc}],
        limit: nil,
        offset: nil,
        select: [:id, :started_at, :user_id, :game_id],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)

      refute String.contains?(cql, "ORDER BY"),
             "ORDER BY must be dropped for secondary index scans"

      assert cql ==
               "SELECT id, started_at, user_id, game_id FROM game_members WHERE user_id = ?"

      assert params == ["u1"]
    end

    test "ORDER BY is preserved when querying via primary key (not secondary index)" do
      filter = %{operator: :eq, left: %{name: :game_id}, right: %{value: "g1"}}

      query = %DataLayer{
        resource: IndexedMember,
        repo: nil,
        table: "game_members",
        filters: [filter],
        sorts: [{:started_at, :desc}],
        limit: nil,
        offset: nil,
        select: [:id, :started_at, :user_id, :game_id],
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "ORDER BY"), "ORDER BY must be preserved for PK queries"
    end

    test "ORDER BY is dropped when filter uses Ash.Query.Ref on secondary index column" do
      filter = %Ash.Query.Ref{attribute: %{name: :user_id}}

      query = %DataLayer{
        resource: IndexedMember,
        repo: nil,
        table: "game_members",
        filters: [filter],
        sorts: [{:started_at, :desc}],
        limit: nil,
        offset: nil,
        select: [:id, :started_at, :user_id, :game_id],
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)

      refute String.contains?(cql, "ORDER BY"),
             "ORDER BY must be dropped when filter uses Ash.Query.Ref on secondary index column"
    end

    test "ORDER BY is dropped when filter uses Ash.Query.Ref with atom attribute on indexed column" do
      filter = %Ash.Query.Ref{attribute: :status}

      query = %DataLayer{
        resource: IndexedMember,
        repo: nil,
        table: "game_members",
        filters: [filter],
        sorts: [{:started_at, :desc}],
        limit: nil,
        offset: nil,
        select: [:id, :started_at, :user_id, :game_id],
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)

      refute String.contains?(cql, "ORDER BY"),
             "ORDER BY must be dropped when filter uses Ash.Query.Ref with atom attribute"
    end

    test "ORDER BY is preserved when Ash.Query.Ref points to non-indexed column" do
      filter = %Ash.Query.Ref{attribute: %{name: :game_id}}

      query = %DataLayer{
        resource: IndexedMember,
        repo: nil,
        table: "game_members",
        filters: [filter],
        sorts: [{:started_at, :desc}],
        limit: nil,
        offset: nil,
        select: [:id, :started_at, :user_id, :game_id],
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)

      assert String.contains?(cql, "ORDER BY"),
             "ORDER BY must be preserved when Ash.Query.Ref points to non-indexed column"
    end

    test "ORDER BY is preserved when resource has NO secondary indexes" do
      filter = %{operator: :eq, left: %{name: :user_id}, right: %{value: "u1"}}

      query = %DataLayer{
        resource: NonIndexedMember,
        repo: nil,
        table: "game_members",
        filters: [filter],
        sorts: [{:started_at, :desc}],
        limit: nil,
        offset: nil,
        select: [:id, :started_at, :user_id, :game_id],
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)

      assert String.contains?(cql, "ORDER BY"),
             "ORDER BY must be preserved when no secondary index is involved"
    end
  end

  describe "build_optimized_query/1 with allow_filtering" do
    defmodule AllowFilteringResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes), do: [%{columns: [:email, :status]}]
      def __ash_scylla__(:allow_filtering), do: true
    end

    defmodule DisallowFilteringResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes), do: [%{columns: [:email, :status]}]
      def __ash_scylla__(:allow_filtering), do: false
    end

    defmodule DefaultFilteringResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes), do: [%{columns: [:email, :status]}]
    end

    test "appends ALLOW FILTERING when enabled and secondary index scan detected" do
      filter = %{operator: :eq, left: %{name: :email}, right: %{value: "a@b.com"}}

      query = %DataLayer{
        resource: AllowFilteringResource,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [:id, :email],
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)

      assert String.contains?(cql, "ALLOW FILTERING"),
             "ALLOW FILTERING must be present when enabled and secondary index scan detected"

      assert cql ==
               "SELECT id, email FROM users WHERE email = ? ALLOW FILTERING"
    end

    test "does NOT append ALLOW FILTERING when disabled even with secondary index scan" do
      filter = %{operator: :eq, left: %{name: :email}, right: %{value: "a@b.com"}}

      query = %DataLayer{
        resource: DisallowFilteringResource,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [:id, :email],
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)

      refute String.contains?(cql, "ALLOW FILTERING"),
             "ALLOW FILTERING must NOT be present when disabled"

      assert cql == "SELECT id, email FROM users WHERE email = ?"
    end

    test "does NOT append ALLOW FILTERING when not set (default false) with secondary index scan" do
      filter = %{operator: :eq, left: %{name: :email}, right: %{value: "a@b.com"}}

      query = %DataLayer{
        resource: DefaultFilteringResource,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [:id, :email],
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)

      refute String.contains?(cql, "ALLOW FILTERING"),
             "ALLOW FILTERING must NOT be present when not configured (default false)"
    end

    test "does NOT append ALLOW FILTERING when enabled but no secondary index scan" do
      filter = %{operator: :eq, left: %{name: :id}, right: %{value: "uuid-123"}}

      query = %DataLayer{
        resource: AllowFilteringResource,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [:id, :email],
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)

      refute String.contains?(cql, "ALLOW FILTERING"),
             "ALLOW FILTERING must NOT be present when filter is not on indexed column"
    end

    test "appends ALLOW FILTERING with multiple indexed filter columns" do
      f1 = %{operator: :eq, left: %{name: :email}, right: %{value: "a@b.com"}}
      f2 = %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}

      query = %DataLayer{
        resource: AllowFilteringResource,
        repo: nil,
        table: "users",
        filters: [f1, f2],
        sorts: [],
        limit: 10,
        offset: nil,
        select: [:id, :email, :status],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)

      assert String.contains?(cql, "ALLOW FILTERING"),
             "ALLOW FILTERING must be present for multi-column secondary index scan"

      assert String.contains?(cql, "LIMIT ?")
      assert "a@b.com" in params
      assert "active" in params
      assert {"int", 10} in params
    end

    test "appends ALLOW FILTERING with Ash.Query.Ref filter on indexed column" do
      filter = %Ash.Query.Ref{attribute: %{name: :email}}

      query = %DataLayer{
        resource: AllowFilteringResource,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [:id, :email],
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)

      assert String.contains?(cql, "ALLOW FILTERING"),
             "ALLOW FILTERING must be present when Ash.Query.Ref filter targets indexed column"
    end

    test "does NOT append ALLOW FILTERING when resource is nil" do
      filter = %{operator: :eq, left: %{name: :email}, right: %{value: "a@b.com"}}

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [:id, :email],
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)

      refute String.contains?(cql, "ALLOW FILTERING"),
             "ALLOW FILTERING must NOT be appended when resource is nil"
    end

    test "ALLOW FILTERING appears after LIMIT in the CQL string" do
      filter = %{operator: :eq, left: %{name: :email}, right: %{value: "a@b.com"}}

      query = %DataLayer{
        resource: AllowFilteringResource,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [],
        limit: 5,
        offset: nil,
        select: [:id, :email],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)

      assert cql ==
               "SELECT id, email FROM users WHERE email = ? LIMIT ? ALLOW FILTERING"

      assert params == ["a@b.com", {"int", 5}]
    end
  end

  # ============================================================================
  # secondary_index_scan?/2
  # ============================================================================

  describe "secondary_index_scan?/2" do
    defmodule TestResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes), do: [%{columns: [:user_id, :status, :email]}]
    end

    defmodule NoIndexResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes), do: []
    end

    test "returns true when all filter columns are indexed" do
      filters = [%{operator: :eq, left: %{name: :user_id}, right: %{value: "abc"}}]
      assert QueryBuilder.secondary_index_scan?(TestResource, filters)
    end

    test "returns true when multiple indexed columns are filtered" do
      f1 = %{operator: :eq, left: %{name: :user_id}, right: %{value: "abc"}}
      f2 = %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
      assert QueryBuilder.secondary_index_scan?(TestResource, [f1, f2])
    end

    test "returns false when filter columns are NOT indexed" do
      filters = [%{operator: :eq, left: %{name: :name}, right: %{value: "foo"}}]
      refute QueryBuilder.secondary_index_scan?(TestResource, filters)
    end

    test "returns false when some columns are indexed and some are not" do
      f1 = %{operator: :eq, left: %{name: :user_id}, right: %{value: "abc"}}
      f2 = %{operator: :eq, left: %{name: :name}, right: %{value: "foo"}}
      refute QueryBuilder.secondary_index_scan?(TestResource, [f1, f2])
    end

    test "returns false when resource has no secondary indexes" do
      filters = [%{operator: :eq, left: %{name: :user_id}, right: %{value: "abc"}}]
      refute QueryBuilder.secondary_index_scan?(NoIndexResource, filters)
    end

    test "returns false for empty filters" do
      refute QueryBuilder.secondary_index_scan?(TestResource, [])
    end

    test "returns true when filter uses Ash.Query.Ref with attribute map" do
      filters = [%Ash.Query.Ref{attribute: %{name: :user_id}}]
      assert QueryBuilder.secondary_index_scan?(TestResource, filters)
    end

    test "returns true when filter uses Ash.Query.Ref with attribute atom" do
      filters = [%Ash.Query.Ref{attribute: :status}]
      assert QueryBuilder.secondary_index_scan?(TestResource, filters)
    end

    test "returns false when Ash.Query.Ref points to non-indexed column" do
      filters = [%Ash.Query.Ref{attribute: %{name: :name}}]
      refute QueryBuilder.secondary_index_scan?(TestResource, filters)
    end

    test "returns true when mixed Ref and plain map filters are all indexed" do
      ref_filter = %Ash.Query.Ref{attribute: %{name: :user_id}}
      plain_filter = %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
      assert QueryBuilder.secondary_index_scan?(TestResource, [ref_filter, plain_filter])
    end

    test "returns false when one Ref filter is indexed and another is not" do
      ref_indexed = %Ash.Query.Ref{attribute: :email}
      ref_unindexed = %Ash.Query.Ref{attribute: :name}
      refute QueryBuilder.secondary_index_scan?(TestResource, [ref_indexed, ref_unindexed])
    end
  end

  # ============================================================================
  # filter_to_cql/1
  # ============================================================================

  describe "filter_to_cql/1" do
    test "simple equality" do
      filter = %{operator: :eq, left: %{name: "name"}, right: %{value: "John"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql == "name = ?"
      assert params == ["John"]
    end

    test "greater than" do
      filter = %{operator: :gt, left: %{name: "age"}, right: %{value: 21}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql == "age > ?"
      assert params == [21]
    end

    test "less than or equal" do
      filter = %{operator: :lte, left: %{name: "price"}, right: %{value: 100}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql == "price <= ?"
      assert params == [100]
    end

    test "not equal" do
      filter = %{operator: :not_eq, left: %{name: "status"}, right: %{value: "deleted"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql == "status != ?"
      assert params == ["deleted"]
    end

    test "contains uses LIKE" do
      filter = %{operator: :contains, left: %{name: "bio"}, right: %{value: "elixir"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert String.contains?(cql, "LIKE")
      assert params == ["%elixir%"]
    end

    test "starts_with uses LIKE with wildcard suffix" do
      filter = %{operator: :starts_with, left: %{name: "name"}, right: %{value: "Jo"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert String.contains?(cql, "LIKE")
      refute String.contains?(cql, "%?")
      assert params == ["%Jo"]
    end

    test "ends_with uses LIKE with wildcard prefix" do
      filter = %{operator: :ends_with, left: %{name: "email"}, right: %{value: ".com"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert String.contains?(cql, "LIKE")
      refute String.contains?(cql, "?%")
      assert params == [".com%"]
    end

    test "expression wrapper unwraps and converts" do
      filter = %{expression: %{operator: :eq, left: %{name: "id"}, right: %{value: 1}}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql == "id = ?"
      assert params == [1]
    end
  end

  # ============================================================================
  # build_where_clause/1
  # ============================================================================

  describe "build_where_clause/1" do
    test "empty list returns empty clause" do
      {cql, params} = QueryBuilder.build_where_clause([])
      assert cql == ""
      assert params == []
    end

    test "single filter produces correct WHERE clause" do
      filter = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
      {cql, params} = QueryBuilder.build_where_clause([filter])
      assert cql == "status = ?"
      assert params == ["active"]
    end

    test "multiple filters are joined with AND" do
      f1 = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
      f2 = %{operator: :gt, left: %{name: "age"}, right: %{value: 18}}
      {cql, params} = QueryBuilder.build_where_clause([f1, f2])
      assert cql == "status = ? AND age > ?"
      assert params == ["active", 18]
    end
  end

  # ============================================================================
  # build_order_by/1
  # ============================================================================

  describe "build_order_by/1" do
    test "empty list returns empty clause" do
      {cql, params} = QueryBuilder.build_order_by([])
      assert cql == ""
      assert params == []
    end

    test "map format with field and direction" do
      {cql, params} = QueryBuilder.build_order_by([%{field: :name, direction: :asc}])
      assert cql == "name asc"
      assert params == []
    end

    test "tuple format" do
      {cql, params} = QueryBuilder.build_order_by([{:created_at, :desc}])
      assert cql == "created_at desc"
      assert params == []
    end

    test "multiple sorts are comma separated" do
      {cql, params} = QueryBuilder.build_order_by([{:name, :asc}, {:created_at, :desc}])
      assert cql == "name asc, created_at desc"
      assert params == []
    end
  end

  # ============================================================================
  # can_use_secondary_index?/2
  # ============================================================================

  describe "can_use_secondary_index?/2" do
    defmodule IndexedResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes), do: [%{columns: [:status, :email]}]
    end

    defmodule UnindexedResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes), do: []
    end

    test "all filter columns indexed returns ok with columns" do
      filters = [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}]
      result = QueryBuilder.can_use_secondary_index?(IndexedResource, filters)
      assert {:ok, [:status]} = result
    end

    test "no indexes returns missing_indexes error" do
      filters = [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}]
      result = QueryBuilder.can_use_secondary_index?(UnindexedResource, filters)
      assert {:error, {:missing_indexes, _}} = result
    end

    test "empty filters returns no_filters error" do
      result = QueryBuilder.can_use_secondary_index?(IndexedResource, [])
      assert result == {:error, :no_filters}
    end
  end
end

# ============================================================================
# Pagination Tests
# ============================================================================

defmodule AshScylla.DataLayer.PaginationTest do
  @moduledoc """
  Comprehensive tests for AshScylla.DataLayer.Pagination module.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Pagination

  describe "build_paginated_query/4" do
    test "no filters, no token produces simple LIMIT query" do
      {cql, params} = Pagination.build_paginated_query("users", %{}, nil, 10)
      assert cql == "SELECT * FROM users LIMIT ?"
      assert params == [10]
    end

    test "with filters includes WHERE clause" do
      {cql, params} = Pagination.build_paginated_query("users", %{status: "active"}, nil, 20)
      assert String.contains?(cql, "WHERE")
      assert String.contains?(cql, "LIMIT ?")
      assert "active" in params
      assert 20 in params
    end

    test "with token includes token() condition" do
      {cql, params} = Pagination.build_paginated_query("users", %{}, "some_token", 10)
      assert String.contains?(cql, "token() > ?")
      assert "some_token" in params
      assert 10 in params
    end

    test "with both filters and token" do
      {cql, params} =
        Pagination.build_paginated_query("users", %{status: "active"}, "page_token", 15)

      assert String.contains?(cql, "WHERE")
      assert String.contains?(cql, "token() > ?")
      assert String.contains?(cql, "LIMIT ?")
      assert "active" in params
      assert "page_token" in params
      assert 15 in params
    end
  end
end
