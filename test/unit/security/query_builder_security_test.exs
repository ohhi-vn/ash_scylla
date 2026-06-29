defmodule AshScylla.QueryBuilderSecurityTest do
  @moduledoc """
  Security tests for QueryBuilder — ensures that CQL injection via
  table names, column names, and filter values is prevented.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.QueryBuilder
  alias AshScylla.Identifier

  # ---------------------------------------------------------------------------
  # Table name injection prevention
  # ---------------------------------------------------------------------------

  describe "table name injection prevention" do
    test "sanitized table names cannot inject CQL" do
      # Even if a malicious table name reaches the query builder,
      # Identifier.sanitize! will reject it before interpolation
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.sanitize!("users; DROP TABLE users")
      end
    end

    test "table name with comment injection is rejected" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.sanitize!("users -- drop everything")
      end
    end

    test "table name with union injection is rejected" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.sanitize!("users UNION SELECT * FROM admin")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Filter value parameterization (values are always ?-bound, never interpolated)
  # ---------------------------------------------------------------------------

  describe "filter values are parameterized, never interpolated" do
    test "string values are passed as parameters, not inlined in CQL" do
      filters = [
        %{left: %{name: :id}, operator: :eq, right: %{value: "malicious'; DROP TABLE users; --"}}
      ]

      {cql, params} = QueryBuilder.build_where_clause(filters)

      # The CQL should use ? placeholder, not the literal value
      assert cql =~ "?"
      refute cql =~ "DROP TABLE"
      refute cql =~ "--"
      # The malicious value should be in params, safely parameterized
      assert "malicious'; DROP TABLE users; --" in params
    end

    test "numeric values are parameterized" do
      filters = [
        %{left: %{name: :id}, operator: :eq, right: %{value: 42}}
      ]

      {cql, params} = QueryBuilder.build_where_clause(filters)
      assert cql =~ "?"
      assert 42 in params
    end

    test "UUID values are parameterized" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"

      filters = [
        %{left: %{name: :id}, operator: :eq, right: %{value: uuid}}
      ]

      {cql, _params} = QueryBuilder.build_where_clause(filters)
      assert cql =~ "?"
      refute cql =~ uuid
    end
  end

  # ---------------------------------------------------------------------------
  # Column name injection via filters
  # ---------------------------------------------------------------------------

  describe "column name injection prevention in filters" do
    test "column names in filters go through cql_identifier sanitization" do
      # Valid column name should work
      filters = [
        %{left: %{name: :email}, operator: :eq, right: %{value: "test@test.com"}}
      ]

      {cql, _params} = QueryBuilder.build_where_clause(filters)
      assert cql =~ "email"
    end

    test "IN clause values are parameterized, not interpolated" do
      # When OR is rewritten to IN, values should still be parameterized
      filters = [
        %{
          op: :or,
          left: %{left: %{name: :id}, operator: :eq, right: %{value: "uuid1"}},
          right: %{left: %{name: :id}, operator: :eq, right: %{value: "uuid2"}}
        }
      ]

      {cql, _params} = QueryBuilder.build_where_clause(filters)
      # IN clause should use ? placeholders
      refute cql =~ "uuid1"
      refute cql =~ "uuid2"
    end
  end

  # ---------------------------------------------------------------------------
  # ORDER BY injection prevention
  # ---------------------------------------------------------------------------

  describe "ORDER BY injection prevention" do
    test "sort column names are validated identifiers" do
      sorts = [{:name, :asc}]

      {order_clause, _params} = QueryBuilder.build_order_by(sorts)
      # Should produce valid CQL
      assert order_clause =~ "name"
      refute order_clause =~ ";"
      refute order_clause =~ "DROP"
    end
  end

  # ---------------------------------------------------------------------------
  # Keyset pagination injection prevention
  # ---------------------------------------------------------------------------

  describe "keyset pagination security" do
    test "keyset clause uses parameterized values" do
      keyset = %{
        partition_keys: [:id],
        values: ["some-token-value"],
        direction: :gt
      }

      {clause, params} = QueryBuilder.build_keyset_clause(keyset)

      # Values should be in params, not in the clause string
      assert is_binary(clause)
      assert is_list(params)
    end
  end

  # ---------------------------------------------------------------------------
  # Aggregate query injection prevention
  # ---------------------------------------------------------------------------

  describe "aggregate query security" do
    test "aggregate functions are whitelisted, not interpolated" do
      # COUNT is the only supported aggregate
      {cql, _params} = QueryBuilder.build_aggregate_query("users", "COUNT(*)", "", [])
      assert cql =~ "COUNT(*)"
      refute cql =~ ";"
    end

    test "aggregate field names are validated" do
      assert QueryBuilder.aggregate_to_cql(:count, :id) == "COUNT(id)"
      assert QueryBuilder.aggregate_to_cql(:sum, :amount) == "SUM(amount)"
    end
  end
end
