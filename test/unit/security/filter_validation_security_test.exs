defmodule AshScylla.FilterValidationSecurityTest do
  @moduledoc """
  Security tests for filter validation — ensures that queries on unindexed
  columns are rejected at query-plan time, preventing full table scans
  and potential DoS via ALLOW FILTERING.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.FilterValidator
  alias AshScylla.DataLayer.Dsl

  # ---------------------------------------------------------------------------
  # Filter on unindexed columns must be rejected
  # ---------------------------------------------------------------------------

  describe "filter validation prevents full table scans" do
    test "raises on filter with non-indexed, non-PK column" do
      # TestResource has :name and :email indexed, but :age is NOT indexed
      filters = [%{left: %{name: :age}, operator: :gt, right: %{value: 25}}]

      assert_raise AshScylla.Error, ~r/unindexed|secondary_index|scylla/, fn ->
        FilterValidator.validate_filters(AshScylla.TestResource, filters)
      end
    end

    test "raises with actionable error message pointing to scylla block" do
      # :password_hash is not indexed and not PK
      filters = [%{left: %{name: :password_hash}, operator: :eq, right: %{value: "hash"}}]

      assert_raise AshScylla.Error, fn ->
        FilterValidator.validate_filters(AshScylla.TestResource, filters)
      end
    end

    test "allows filter on primary key column" do
      # :id is the primary key — filtering on it is always safe
      filters = [%{left: %{name: :id}, operator: :eq, right: %{value: "uuid"}}]

      # Should not raise
      assert FilterValidator.validate_filters(AshScylla.TestResource, filters) == :ok
    end

    test "allows filter on indexed column" do
      # TestResource has :email as a secondary index
      filters = [%{left: %{name: :email}, operator: :eq, right: %{value: "a@b.com"}}]

      assert FilterValidator.validate_filters(AshScylla.TestResource, filters) == :ok
    end

    test "rejects filter mixing indexed and unindexed columns" do
      # TestResource has :email indexed but :age is NOT indexed
      filters = [
        %{left: %{name: :email}, operator: :eq, right: %{value: "a@b.com"}},
        %{left: %{name: :age}, operator: :eq, right: %{value: 30}}
      ]

      assert_raise AshScylla.Error, ~r/unindexed|secondary_index/, fn ->
        FilterValidator.validate_filters(AshScylla.TestResource, filters)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ALLOW FILTERING must never be generated
  # ---------------------------------------------------------------------------

  describe "ALLOW FILTERING is never appended to queries" do
    test "QueryBuilder never produces ALLOW FILTERING in output" do
      alias AshScylla.DataLayer.QueryBuilder

      query = %AshScylla.Query{
        resource: AshScylla.TestResource,
        repo: nil,
        table: "test_table",
        filters: [%{left: %{name: :id}, operator: :eq, right: %{value: "uuid"}}],
        sorts: [],
        limit: 10
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)
      refute cql =~ "ALLOW FILTERING"
    end

    test "QueryBuilder output never contains ALLOW FILTERING even with complex filters" do
      alias AshScylla.DataLayer.QueryBuilder

      query = %AshScylla.Query{
        resource: AshScylla.TestResource,
        repo: nil,
        table: "test_table",
        filters: [
          %{left: %{name: :id}, operator: :eq, right: %{value: "uuid"}},
          %{left: %{name: :email}, operator: :eq, right: %{value: "active"}}
        ],
        sorts: [],
        limit: 50
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)
      refute cql =~ "ALLOW FILTERING"
    end
  end

  # ---------------------------------------------------------------------------
  # OFFSET must never appear in generated CQL
  # ---------------------------------------------------------------------------

  describe "OFFSET is never generated in CQL" do
    test "QueryBuilder never produces OFFSET in output" do
      alias AshScylla.DataLayer.QueryBuilder

      query = %AshScylla.Query{
        resource: AshScylla.TestResource,
        repo: nil,
        table: "test_table",
        filters: [],
        sorts: [],
        limit: 10
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)
      refute cql =~ ~r/\bOFFSET\b/i
    end
  end

  # ---------------------------------------------------------------------------
  # queryable_columns/1 returns only safe columns
  # ---------------------------------------------------------------------------

  describe "queryable_columns/1 security" do
    test "returns only PK + indexed columns, never all columns" do
      queryable = FilterValidator.queryable_columns(AshScylla.TestResource)

      # Should include PK columns
      assert :id in queryable
      # Should include indexed columns
      assert :name in queryable
      assert :email in queryable
      # Should NOT include unindexed non-PK columns
      refute :age in queryable
      refute :password_hash in queryable
    end
  end
end
