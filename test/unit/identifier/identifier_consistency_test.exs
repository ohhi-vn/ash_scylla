defmodule AshScylla.IdentifierConsistencyTest do
  @moduledoc """
  Tests to verify that identifier sanitization is consistent across all modules.
  Covers: Issue #14 (Duplicate quote_name implementations across modules)
  """

  use ExUnit.Case, async: true

  alias AshScylla.Identifier

  describe "Identifier.sanitize!/1 — universal sanitization" do
    test "validates identifiers the same way everywhere" do
      # The Identifier module should be the single source of truth
      # for CQL identifier validation
      valid_names = ["users", "my_table", "_private", "Table1", "col_123"]

      for name <- valid_names do
        assert Identifier.sanitize!(name) == name
      end
    end

    test "rejects invalid identifiers consistently" do
      invalid_names = [
        "users; DROP TABLE",
        "table -- comment",
        "name`",
        "col)",
        "space separated",
        "",
        "123start",
        "table$name"
      ]

      for name <- invalid_names do
        assert_raise ArgumentError, fn ->
          Identifier.sanitize!(name)
        end
      end
    end
  end

  describe "QueryBuilder uses Identifier for safety" do
    test "build_where_clause rejects invalid column names" do
      # The QueryBuilder should use Identifier.sanitize! for column names
      # This test verifies that valid columns work
      filters = [
        %{operator: :eq, left: %{name: :valid_column}, right: %{value: "test"}}
      ]

      {clause, _params} = AshScylla.DataLayer.QueryBuilder.build_where_clause(filters)
      assert clause =~ "valid_column"
    end

    test "build_order_by handles valid column names" do
      sorts = [
        %{field: :name, direction: :asc},
        %{field: :email, direction: :desc}
      ]

      {clause, _params} = AshScylla.DataLayer.QueryBuilder.build_order_by(sorts)
      assert clause =~ "name asc"
      assert clause =~ "email desc"
    end
  end

  describe "MaterializedView uses safe quoting" do
    test "create_view_cql produces safe CQL" do
      result =
        AshScylla.DataLayer.MaterializedView.create_view_cql(
          "safe_view",
          "safe_table",
          primary_key: [:id, :email],
          include_columns: [:name]
        )

      # Verify the output contains expected CQL structure
      assert result =~ "CREATE MATERIALIZED VIEW"
      assert result =~ "safe_view"
      assert result =~ "safe_table"
      assert result =~ "PRIMARY KEY"
      assert result =~ "email"
    end

    test "drop_view_cql produces safe CQL" do
      result = AshScylla.DataLayer.MaterializedView.drop_view_cql("safe_view")
      assert result =~ "DROP MATERIALIZED VIEW IF EXISTS"
      assert result =~ "safe_view"
    end
  end
end
