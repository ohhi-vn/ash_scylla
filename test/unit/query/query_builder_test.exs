defmodule AshScylla.DataLayer.QueryBuilderTest do
  @moduledoc """
  Comprehensive tests for AshScylla.DataLayer.QueryBuilder and
  AshScylla.DataLayer.Pagination modules.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.Pagination
  alias AshScylla.DataLayer.QueryBuilder

  # ============================================================================
  # build_optimized_query/1
  # ============================================================================

  describe "build_optimized_query/1" do
    test "simple SELECT * with no filters, sorts, or limit" do
      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, params}} = QueryBuilder.build_optimized_query(query)
      assert cql == "SELECT * FROM users"
      assert params == []
    end

    test "SELECT with specific columns" do
      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [],
        sorts: [],
        limit: nil,
        select: [:name, :email],
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert cql == "SELECT name, email FROM users"
    end

    test "SELECT with single equality filter" do
      filter = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}

      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, params}} = QueryBuilder.build_optimized_query(query)
      assert cql == "SELECT * FROM users WHERE status = ?"
      assert params == ["active"]
    end

    test "SELECT with multiple filters joined by AND" do
      f1 = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
      f2 = %{operator: :gt, left: %{name: "age"}, right: %{value: 18}}

      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [f1, f2],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "WHERE")
      assert String.contains?(cql, "AND")
    end

    test "SELECT with ORDER BY" do
      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [],
        sorts: [{:name, :asc}],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "ORDER BY name asc")
    end

    test "SELECT with LIMIT" do
      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [],
        sorts: [],
        limit: 10,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "LIMIT ?")
      assert {"int", 10} in params
    end

    test "combined: filter + sort + limit" do
      filter = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}

      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [{:created_at, :desc}],
        limit: 25,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "WHERE")
      assert String.contains?(cql, "ORDER BY created_at desc")
      assert String.contains?(cql, "LIMIT ?")
      assert "active" in params
      assert {"int", 25} in params
    end

    test "IN operator filter" do
      filter = %{operator: :in, left: %{name: "status"}, right: %{value: ["active", "pending"]}}

      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "IN")
      assert params == ["active", "pending"]
    end

    test "nested AND produces flat chain without extra parentheses" do
      filter = %{
        op: :and,
        left: %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}},
        right: %{operator: :gt, left: %{name: "age"}, right: %{value: 18}}
      }

      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "users",
        filters: [filter],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, params}} = QueryBuilder.build_optimized_query(query)
      assert cql == "SELECT * FROM users WHERE status = ? AND age > ?"
      assert params == ["active", 18]
    end

    test "chained AND filters should NOT produce double parentheses" do
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

      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "game_members",
        filters: [outer],
        sorts: [{:started_at, :desc}],
        limit: nil,
        select: [:id, :started_at, :user_id, :game_id, :is_admin],
        tenant: nil
      }

      {:ok, {cql, params}} = QueryBuilder.build_optimized_query(query)

      refute String.contains?(cql, "(("), "CQL must not contain double opening parens"
      refute String.contains?(cql, "))"), "CQL must not contain double closing parens"

      assert cql ==
               "SELECT id, started_at, user_id, game_id, is_admin FROM game_members WHERE user_id = ? AND started_at >= ? AND started_at <= ? ORDER BY started_at desc"

      assert params == ["u1", "2026-01-01", "2026-12-31"]
    end
  end

  describe "build_optimized_query/1 with secondary index scan" do
    defmodule IndexedMember do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes),
        do: [
          %{columns: [:user_id], name: nil, options: []},
          %{columns: [:game_id], name: nil, options: []}
        ]

      def __ash_scylla__(:table), do: "game_members"
      def __ash_scylla__(:keyspace), do: "test_ks"
      def __ash_scylla__(_), do: nil
    end

    defmodule NonIndexedMember do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes), do: []
      def __ash_scylla__(:table), do: "game_members"
      def __ash_scylla__(:keyspace), do: "test_ks"
      def __ash_scylla__(_), do: nil
    end

    test "ORDER BY is dropped and ALLOW FILTERING is appended when scanning via secondary index" do
      filter = %{operator: :eq, left: %{name: "user_id"}, right: %{value: "u1"}}

      query = %AshScylla.Query{
        resource: IndexedMember,
        repo: nil,
        table: "game_members",
        filters: [filter],
        sorts: [{:created_at, :desc}],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)

      refute String.contains?(cql, "ORDER BY"),
             "ORDER BY should be dropped for secondary index scan"

      assert String.contains?(cql, "ALLOW FILTERING"), "ALLOW FILTERING should be appended"
    end

    test "ORDER BY is preserved when querying via primary key (not secondary index)" do
      filter = %{operator: :eq, left: %{name: "id"}, right: %{value: "abc"}}

      query = %AshScylla.Query{
        resource: IndexedMember,
        repo: nil,
        table: "game_members",
        filters: [filter],
        sorts: [{:created_at, :desc}],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)

      assert String.contains?(cql, "ORDER BY"),
             "ORDER BY should be preserved for primary key query"

      refute String.contains?(cql, "ALLOW FILTERING"), "ALLOW FILTERING should not be appended"
    end

    test "ORDER BY is dropped when filter uses Ash.Query.Ref on secondary index column" do
      ref = struct(Ash.Query.Ref, attribute: %{name: :user_id, type: :string})
      filter = %{operator: :eq, left: ref, right: %{value: "u1"}}

      query = %AshScylla.Query{
        resource: IndexedMember,
        repo: nil,
        table: "game_members",
        filters: [filter],
        sorts: [{:created_at, :desc}],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      refute String.contains?(cql, "ORDER BY"), "ORDER BY should be dropped"
      assert String.contains?(cql, "ALLOW FILTERING"), "ALLOW FILTERING should be appended"
    end

    test "ORDER BY is dropped when filter uses Ash.Query.Ref with atom attribute on indexed column" do
      ref = struct(Ash.Query.Ref, attribute: :user_id)
      filter = %{operator: :eq, left: ref, right: %{value: "u1"}}

      query = %AshScylla.Query{
        resource: IndexedMember,
        repo: nil,
        table: "game_members",
        filters: [filter],
        sorts: [{:created_at, :desc}],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      refute String.contains?(cql, "ORDER BY"), "ORDER BY should be dropped"
      assert String.contains?(cql, "ALLOW FILTERING"), "ALLOW FILTERING should be appended"
    end

    test "ORDER BY is preserved when Ash.Query.Ref points to non-indexed column" do
      ref = struct(Ash.Query.Ref, attribute: %{name: :non_indexed, type: :string})
      filter = %{operator: :eq, left: ref, right: %{value: "val"}}

      query = %AshScylla.Query{
        resource: IndexedMember,
        repo: nil,
        table: "game_members",
        filters: [filter],
        sorts: [{:created_at, :desc}],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "ORDER BY"), "ORDER BY should be preserved"
      refute String.contains?(cql, "ALLOW FILTERING"), "ALLOW FILTERING should not be appended"
    end

    test "ORDER BY is preserved when resource has NO secondary indexes" do
      filter = %{operator: :eq, left: %{name: "user_id"}, right: %{value: "u1"}}

      query = %AshScylla.Query{
        resource: NonIndexedMember,
        repo: nil,
        table: "game_members",
        filters: [filter],
        sorts: [{:created_at, :desc}],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "ORDER BY"), "ORDER BY should be preserved"
      refute String.contains?(cql, "ALLOW FILTERING"), "ALLOW FILTERING should not be appended"
    end
  end

  describe "build_optimized_query/1 with multiple indexed columns" do
    defmodule ScanTestResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes),
        do: [
          %{columns: [:name], name: nil, options: []},
          %{columns: [:email], name: nil, options: []}
        ]

      def __ash_scylla__(:table), do: "test_members"
      def __ash_scylla__(:keyspace), do: "test_ks"
      def __ash_scylla__(_), do: nil
    end

    test "builds correct query with multiple indexed filter columns" do
      f1 = %{operator: :eq, left: %{name: "name"}, right: %{value: "John"}}
      f2 = %{operator: :eq, left: %{name: "email"}, right: %{value: "john@test.com"}}

      query = %AshScylla.Query{
        resource: ScanTestResource,
        repo: nil,
        table: "test_members",
        filters: [f1, f2],
        sorts: [{:name, :asc}],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "WHERE")
      assert String.contains?(cql, "ALLOW FILTERING")
    end
  end

  describe "build_optimized_query/1 ALLOW FILTERING for secondary index scans" do
    defmodule AllowFilterResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes),
        do: [
          %{columns: [:email], name: nil, options: []},
          %{columns: [:name], name: nil, options: []}
        ]

      def __ash_scylla__(:table), do: "test_members"
      def __ash_scylla__(:keyspace), do: "test_ks"
      def __ash_scylla__(_), do: nil
    end

    defmodule AllowFilterPKResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes),
        do: [
          %{columns: [:email], name: nil, options: []},
          %{columns: [:name], name: nil, options: []}
        ]

      def __ash_scylla__(:table), do: "test_members"
      def __ash_scylla__(:keyspace), do: "test_ks"
      def __ash_scylla__(_), do: nil
    end

    test "appends ALLOW FILTERING when filtering on single secondary index column" do
      filter = %{operator: :eq, left: %{name: "email"}, right: %{value: "a@b.com"}}

      query = %AshScylla.Query{
        resource: AllowFilterResource,
        repo: nil,
        table: "test_members",
        filters: [filter],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "ALLOW FILTERING")
    end

    test "appends ALLOW FILTERING when filtering on multiple secondary index columns" do
      f1 = %{operator: :eq, left: %{name: "email"}, right: %{value: "a@b.com"}}
      f2 = %{operator: :eq, left: %{name: "name"}, right: %{value: "John"}}

      query = %AshScylla.Query{
        resource: AllowFilterResource,
        repo: nil,
        table: "test_members",
        filters: [f1, f2],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "ALLOW FILTERING")
    end

    test "does NOT append ALLOW FILTERING when filtering only by primary key" do
      filter = %{operator: :eq, left: %{name: "id"}, right: %{value: "abc"}}

      query = %AshScylla.Query{
        resource: AllowFilterResource,
        repo: nil,
        table: "test_members",
        filters: [filter],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      refute String.contains?(cql, "ALLOW FILTERING")
    end

    test "does NOT append ALLOW FILTERING when there are no filters" do
      query = %AshScylla.Query{
        resource: AllowFilterResource,
        repo: nil,
        table: "test_members",
        filters: [],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      refute String.contains?(cql, "ALLOW FILTERING")
    end

    test "does NOT append ALLOW FILTERING when resource is nil" do
      filter = %{operator: :eq, left: %{name: "email"}, right: %{value: "a@b.com"}}

      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "test_members",
        filters: [filter],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      refute String.contains?(cql, "ALLOW FILTERING")
    end

    test "appends ALLOW FILTERING with LIMIT and secondary index scan" do
      filter = %{operator: :eq, left: %{name: "email"}, right: %{value: "a@b.com"}}

      query = %AshScylla.Query{
        resource: AllowFilterResource,
        repo: nil,
        table: "test_members",
        filters: [filter],
        sorts: [],
        limit: 10,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "ALLOW FILTERING")
      assert String.contains?(cql, "LIMIT ?")
    end

    test "appends ALLOW FILTERING with ORDER BY stripped and secondary index scan" do
      filter = %{operator: :eq, left: %{name: "email"}, right: %{value: "a@b.com"}}

      query = %AshScylla.Query{
        resource: AllowFilterResource,
        repo: nil,
        table: "test_members",
        filters: [filter],
        sorts: [{:name, :asc}],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "ALLOW FILTERING")
      refute String.contains?(cql, "ORDER BY"), "ORDER BY should be stripped"
    end

    test "appends ALLOW FILTERING when using Ash.Query.Ref on secondary index column" do
      ref = struct(Ash.Query.Ref, attribute: %{name: :email, type: :string})
      filter = %{operator: :eq, left: ref, right: %{value: "a@b.com"}}

      query = %AshScylla.Query{
        resource: AllowFilterResource,
        repo: nil,
        table: "test_members",
        filters: [filter],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "ALLOW FILTERING")
    end

    test "does NOT append ALLOW FILTERING when Ash.Query.Ref points to non-indexed column" do
      ref = struct(Ash.Query.Ref, attribute: %{name: :non_indexed, type: :string})
      filter = %{operator: :eq, left: ref, right: %{value: "val"}}

      query = %AshScylla.Query{
        resource: AllowFilterResource,
        repo: nil,
        table: "test_members",
        filters: [filter],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      refute String.contains?(cql, "ALLOW FILTERING")
    end

    test "appends ALLOW FILTERING with complex AND filters on secondary indexes" do
      inner = %{
        op: :and,
        left: %{operator: :eq, left: %{name: "email"}, right: %{value: "a@b.com"}},
        right: %{operator: :eq, left: %{name: "name"}, right: %{value: "John"}}
      }

      outer = %{
        op: :and,
        left: inner,
        right: %{operator: :eq, left: %{name: "id"}, right: %{value: "abc"}}
      }

      query = %AshScylla.Query{
        resource: AllowFilterResource,
        repo: nil,
        table: "test_members",
        filters: [outer],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert String.contains?(cql, "ALLOW FILTERING")
    end
  end

  describe "secondary_index_scan?/2" do
    defmodule TestResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes),
        do: [
          %{columns: [:email], name: nil, options: []},
          %{columns: [:name], name: nil, options: []}
        ]

      def __ash_scylla__(_), do: nil
    end

    defmodule NoIndexResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes), do: []
      def __ash_scylla__(_), do: nil
    end

    test "returns true when all filter columns are indexed" do
      filters = [%{operator: :eq, left: %{name: "email"}, right: %{value: "a@b.com"}}]
      assert QueryBuilder.secondary_index_scan?(TestResource, filters)
    end

    test "returns true when multiple indexed columns are filtered" do
      filters = [
        %{operator: :eq, left: %{name: "email"}, right: %{value: "a@b.com"}},
        %{operator: :eq, left: %{name: "name"}, right: %{value: "John"}}
      ]

      assert QueryBuilder.secondary_index_scan?(TestResource, filters)
    end

    test "returns false when filter columns are NOT indexed" do
      filters = [%{operator: :eq, left: %{name: "age"}, right: %{value: 30}}]
      refute QueryBuilder.secondary_index_scan?(TestResource, filters)
    end

    test "returns false when some columns are indexed and some are not" do
      filters = [
        %{operator: :eq, left: %{name: "email"}, right: %{value: "a@b.com"}},
        %{operator: :eq, left: %{name: "age"}, right: %{value: 30}}
      ]

      refute QueryBuilder.secondary_index_scan?(TestResource, filters)
    end

    test "returns false when resource has no secondary indexes" do
      filters = [%{operator: :eq, left: %{name: "email"}, right: %{value: "a@b.com"}}]
      refute QueryBuilder.secondary_index_scan?(NoIndexResource, filters)
    end

    test "returns false for empty filters" do
      refute QueryBuilder.secondary_index_scan?(TestResource, [])
    end

    test "returns true when filter uses Ash.Query.Ref with attribute map" do
      ref = struct(Ash.Query.Ref, attribute: %{name: :email, type: :string})
      filter = %{operator: :eq, left: ref, right: %{value: "a@b.com"}}
      assert QueryBuilder.secondary_index_scan?(TestResource, [filter])
    end

    test "returns true when filter uses Ash.Query.Ref with attribute atom" do
      ref = struct(Ash.Query.Ref, attribute: :email)
      filter = %{operator: :eq, left: ref, right: %{value: "a@b.com"}}
      assert QueryBuilder.secondary_index_scan?(TestResource, [filter])
    end

    test "returns false when Ash.Query.Ref points to non-indexed column" do
      ref = struct(Ash.Query.Ref, attribute: %{name: :age, type: :integer})
      filter = %{operator: :eq, left: ref, right: %{value: 30}}
      refute QueryBuilder.secondary_index_scan?(TestResource, [filter])
    end

    test "returns true when mixed Ref and plain map filters are all indexed" do
      ref = struct(Ash.Query.Ref, attribute: %{name: :email, type: :string})

      filters = [
        %{operator: :eq, left: ref, right: %{value: "a@b.com"}},
        %{operator: :eq, left: %{name: "name"}, right: %{value: "John"}}
      ]

      assert QueryBuilder.secondary_index_scan?(TestResource, filters)
    end

    test "returns false when one Ref filter is indexed and another is not" do
      ref = struct(Ash.Query.Ref, attribute: %{name: :email, type: :string})

      filters = [
        %{operator: :eq, left: ref, right: %{value: "a@b.com"}},
        %{operator: :eq, left: %{name: "age"}, right: %{value: 30}}
      ]

      refute QueryBuilder.secondary_index_scan?(TestResource, filters)
    end
  end

  # ============================================================================
  # filter_to_cql/1
  # ============================================================================

  describe "filter_to_cql/1" do
    test "simple equality" do
      filter = %{operator: :eq, left: %{name: "name"}, right: %{value: "John"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "name = ?"
      assert params == ["John"]
    end

    test "greater than" do
      filter = %{operator: :gt, left: %{name: "age"}, right: %{value: 21}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "age > ?"
      assert params == [21]
    end

    test "less than or equal" do
      filter = %{operator: :lte, left: %{name: "price"}, right: %{value: 100}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "price <= ?"
      assert params == [100]
    end

    test "not equal" do
      filter = %{operator: :not_eq, left: %{name: "status"}, right: %{value: "deleted"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "status != ?"
      assert params == ["deleted"]
    end

    test "contains uses LIKE" do
      filter = %{operator: :contains, left: %{name: "bio"}, right: %{value: "elixir"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert String.contains?(cql, "LIKE")
      assert params == ["%elixir%"]
    end

    test "starts_with uses LIKE with wildcard suffix" do
      filter = %{operator: :starts_with, left: %{name: "name"}, right: %{value: "Jo"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert String.contains?(cql, "LIKE")
      refute String.contains?(cql, "%?")
      assert params == ["%Jo"]
    end

    test "ends_with uses LIKE with wildcard prefix" do
      filter = %{operator: :ends_with, left: %{name: "email"}, right: %{value: ".com"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert String.contains?(cql, "LIKE")
      refute String.contains?(cql, "?%")
      assert params == [".com%"]
    end

    test "expression wrapper unwraps and converts" do
      filter = %{expression: %{operator: :eq, left: %{name: "id"}, right: %{value: 1}}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "id = ?"
      assert params == [1]
    end

    test "contains(name, value) function call produces LIKE" do
      filter = %{name: :contains, args: [%{name: "bio"}, %{value: "elixir"}]}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert String.contains?(cql, "LIKE")
      assert params == ["%elixir%"]
    end

    test "contains() via Ash.Query.Call struct produces LIKE" do
      filter = struct(Ash.Query.Call, name: :contains, args: [%{name: "bio"}, %{value: "elixir"}])
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert String.contains?(cql, "LIKE")
      assert params == ["%elixir%"]
    end

    test "starts_with(name, value) function call produces LIKE" do
      filter = %{name: :starts_with, args: [%{name: "name"}, %{value: "jo"}]}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert String.contains?(cql, "LIKE")
      assert params == ["%jo"]
    end

    test "ends_with(name, value) function call produces LIKE" do
      filter = %{name: :ends_with, args: [%{name: "email"}, %{value: ".com"}]}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert String.contains?(cql, "LIKE")
      assert params == [".com%"]
    end

    test "contains() in AND composite filter" do
      contains_filter = %{name: :contains, args: [%{name: "bio"}, %{value: "elixir"}]}
      eq_filter = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}

      and_filter = %{op: :and, left: contains_filter, right: eq_filter}
      {cql, params} = QueryBuilder.filter_to_cql(and_filter, %MapSet{}, %{})
      assert String.contains?(cql, "AND")
      assert String.contains?(cql, "LIKE")
      assert "active" in params
      assert "elixir" in params || "%elixir%" in params
    end
  end

  # ============================================================================
  # build_where_clause/1
  # ============================================================================

  describe "build_where_clause/1" do
    test "empty list returns empty clause" do
      {:ok, {cql, params}} = QueryBuilder.build_where_clause([], %MapSet{}, %{})
      assert cql == ""
      assert params == []
    end

    test "single filter produces correct WHERE clause" do
      filter = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
      {:ok, {cql, params}} = QueryBuilder.build_where_clause([filter], %MapSet{}, %{})
      assert cql == "status = ?"
      assert params == ["active"]
    end

    test "multiple filters are joined with AND" do
      f1 = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
      f2 = %{operator: :gt, left: %{name: "age"}, right: %{value: 18}}
      {:ok, {cql, _params}} = QueryBuilder.build_where_clause([f1, f2], %MapSet{}, %{})
      assert String.contains?(cql, "AND")
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
      {cql, params} = QueryBuilder.build_order_by([{:name, :asc}])
      assert cql == "name asc"
      assert params == []
    end

    test "multiple sorts are comma separated" do
      {cql, _params} = QueryBuilder.build_order_by([{:name, :asc}, {:age, :desc}])
      assert cql == "name asc, age desc"
    end
  end

  # ============================================================================
  # cql_identifier quoting for reserved keywords
  # ============================================================================

  defmodule ReservedKeywordDistinctResource do
    @moduledoc false
    def __ash_scylla__(:secondary_indexes), do: []
    def __ash_scylla__(:table), do: "test_table"
    def __ash_scylla__(:keyspace), do: "test_ks"
    def __ash_scylla__(_), do: nil
  end

  describe "build_select_clause uses cql_identifier for reserved keywords" do
    test "columns with reserved keyword names are quoted" do
      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "test_table",
        filters: [],
        sorts: [],
        limit: nil,
        select: [:group, :order, :select],
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert cql == ~s(SELECT "group", "order", "select" FROM test_table)
    end

    test "all columns are quoted when they are reserved keywords" do
      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "test_table",
        filters: [],
        sorts: [],
        limit: nil,
        select: [:primary, :key, :table, :index, :user],
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert cql == ~s(SELECT "primary", key, "table", "index", user FROM test_table)
    end

    test "DISTINCT columns with reserved keywords are quoted" do
      query = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "test_table",
        filters: [],
        sorts: [],
        limit: nil,
        select: nil,
        distinct: %{column: :group, distinct?: true, keys: []},
        tenant: nil
      }

      {:ok, {cql, _params}} = QueryBuilder.build_optimized_query(query)
      assert cql == ~s(SELECT DISTINCT "group" FROM test_table)
    end
  end

  describe "can_use_secondary_index?/2" do
    defmodule IndexedResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes),
        do: [
          %{columns: [:email], name: nil, options: []},
          %{columns: [:name, :age], name: nil, options: []}
        ]

      def __ash_scylla__(_), do: nil
    end

    defmodule UnindexedResource do
      @moduledoc false
      def __ash_scylla__(:secondary_indexes), do: []
      def __ash_scylla__(_), do: nil
    end

    test "all filter columns indexed returns ok with columns" do
      filters = [%{operator: :eq, left: %{name: "email"}, right: %{value: "a@b.com"}}]
      assert {:ok, [:email]} = QueryBuilder.can_use_secondary_index?(IndexedResource, filters)
    end

    test "no indexes returns missing_indexes error" do
      filters = [%{operator: :eq, left: %{name: "email"}, right: %{value: "a@b.com"}}]

      assert {:error, {:missing_indexes, [:email]}} =
               QueryBuilder.can_use_secondary_index?(UnindexedResource, filters)
    end

    test "empty filters returns no_filters error" do
      assert {:error, :no_filters} = QueryBuilder.can_use_secondary_index?(UnindexedResource, [])
    end
  end

  describe "has operator (Ash.Query.Operator.Has)" do
    test "has with single value -> CONTAINS" do
      filter = %{operator: :has, left: %{name: "tags"}, right: %{value: "admin"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "tags CONTAINS ?"
      assert params == ["admin"]
    end

    test "has via Ash.Query.Operator.Has struct" do
      filter = %Ash.Query.Operator.Has{
        left: %{name: "tags"},
        right: %{value: "admin"}
      }

      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "tags CONTAINS ?"
      assert params == ["admin"]
    end

    test "has with integer value" do
      filter = %{operator: :has, left: %{name: "scores"}, right: %{value: 100}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "scores CONTAINS ?"
      assert params == [100]
    end

    test "has with nil value" do
      filter = %{operator: :has, left: %{name: "tags"}, right: %{value: nil}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "tags CONTAINS ?"
      assert params == [nil]
    end
  end

  describe "overlaps operator (Ash.Query.Operator.Overlaps)" do
    test "overlaps with empty list -> FALSE" do
      filter = %Ash.Query.Operator.Overlaps{
        left: %{name: "tags"},
        right: MapSet.new()
      }

      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "FALSE"
      assert params == []
    end

    test "overlaps with single value -> CONTAINS" do
      filter = %Ash.Query.Operator.Overlaps{
        left: %{name: "tags"},
        right: MapSet.new(["admin"])
      }

      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "tags CONTAINS ?"
      assert params == ["admin"]
    end

    test "overlaps with multiple values -> raises error (CQL has no OR)" do
      filter = %Ash.Query.Operator.Overlaps{
        left: %{name: "tags"},
        right: MapSet.new(["admin", "moderator"])
      }

      assert_raise AshScylla.Error, ~r/does not support OR/, fn ->
        QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      end
    end

    test "overlaps with MapSet of multiple values -> raises error" do
      filter = %Ash.Query.Operator.Overlaps{
        left: %{name: "tags"},
        right: MapSet.new(["admin", "moderator", "user"])
      }

      assert_raise AshScylla.Error, ~r/does not support OR/, fn ->
        QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      end
    end

    test "overlaps via operator dispatch with multi-value list -> raises error" do
      filter = %{
        operator: :overlaps,
        left: %{name: "tags"},
        right: %{value: ["admin", "moderator"]}
      }

      assert_raise AshScylla.Error, ~r/does not support OR/, fn ->
        QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      end
    end

    test "overlaps via operator dispatch with single-element list" do
      filter = %{operator: :overlaps, left: %{name: "tags"}, right: %{value: ["admin"]}}

      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "tags CONTAINS ?"
      assert params == ["admin"]
    end

    test "overlaps via operator dispatch with single-element MapSet" do
      filter = %{
        operator: :overlaps,
        left: %{name: "tags"},
        right: %{value: MapSet.new(["admin"])}
      }

      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "tags CONTAINS ?"
      assert params == ["admin"]
    end

    test "overlaps via operator dispatch with single raw value" do
      filter = %{operator: :overlaps, left: %{name: "tags"}, right: "admin"}

      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "tags CONTAINS ?"
      assert params == ["admin"]
    end
  end

  describe "fragment support" do
    test "fragment with raw CQL and placeholders" do
      filter = %{
        __function__?: true,
        name: :fragment,
        arguments: [
          {:raw, "status = ?"},
          {:expr, "active"}
        ]
      }

      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "status = ?"
      assert params == ["active"]
    end

    test "fragment with casted_expr arguments" do
      filter = %{
        __function__?: true,
        name: :fragment,
        arguments: [
          {:raw, "name = ?"},
          {:casted_expr, "John"}
        ]
      }

      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "name = ?"
      assert params == ["John"]
    end

    test "fragment with only raw CQL (no placeholders)" do
      filter = %{
        __function__?: true,
        name: :fragment,
        arguments: [
          {:raw, "status = 'active'"}
        ]
      }

      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "status = 'active'"
      assert params == []
    end
  end

  describe "expression_calculation support" do
    test "DataLayer.can? returns true for :expression_calculation" do
      assert DataLayer.can?(nil, :expression_calculation)
    end

    test "DataLayer.can? returns true for :expression_calculation with resource" do
      assert DataLayer.can?(nil, :expression_calculation)
    end
  end

  describe "build_paginated_query/4" do
    test "no filters, no token produces simple LIMIT query" do
      {:ok, {cql, params}} = Pagination.build_paginated_query("users", [], nil, 10)
      assert cql == "SELECT * FROM users LIMIT ?"
      assert params == [10]
    end

    test "with filters includes WHERE clause" do
      filter = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
      {:ok, {cql, params}} = Pagination.build_paginated_query("users", [filter], nil, 10)
      assert String.contains?(cql, "WHERE")
      assert String.contains?(cql, "LIMIT ?")
      assert "active" in params
    end

    test "with token includes token() condition" do
      token = %{token: "abc123", partition_key: [:id]}
      {:ok, {cql, _params}} = Pagination.build_paginated_query("users", [], token, 10)
      assert String.contains?(cql, "token()")
      assert String.contains?(cql, "LIMIT ?")
    end

    test "with both filters and token" do
      filter = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
      token = %{token: "abc123", partition_key: [:id]}

      {:ok, {cql, _params}} = Pagination.build_paginated_query("users", [filter], token, 10)
      assert String.contains?(cql, "WHERE")
      assert String.contains?(cql, "AND")
      assert String.contains?(cql, "token()")
      assert String.contains?(cql, "LIMIT ?")
    end
  end
end
