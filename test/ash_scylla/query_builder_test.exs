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
      assert 10 in params
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
      assert 25 in params
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

    test "nested AND/OR filter" do
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
      assert String.contains?(cql, "AND")
      assert "active" in params
      assert 18 in params
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
      assert params == ["elixir"]
    end

    test "starts_with uses LIKE with wildcard suffix" do
      filter = %{operator: :starts_with, left: %{name: "name"}, right: %{value: "Jo"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert String.contains?(cql, "LIKE")
      assert String.contains?(cql, "%?")
      assert params == ["Jo"]
    end

    test "ends_with uses LIKE with wildcard prefix" do
      filter = %{operator: :ends_with, left: %{name: "email"}, right: %{value: ".com"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert String.contains?(cql, "LIKE")
      assert String.contains?(cql, "?%")
      assert params == [".com"]
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
