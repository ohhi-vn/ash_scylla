defmodule AshScylla.FilterValidatorVerifierTest do
  @moduledoc """
  Tests for FilterValidator using Spark.Test patterns.

  The FilterValidator acts as a verifier-like component: it validates filter
  columns against a resource's primary key and secondary indexes, raising
  AshScylla.Error when invalid columns are detected.

  This test module focuses on edge cases and comprehensive coverage:
  - Single and multiple invalid columns
  - Nested filter expressions
  - Composite indexes
  - IN filters
  - Aggregates and calculations
  - Relationship filters
  - Exists filters
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.FilterValidator

  # ---------------------------------------------------------------------------
  # Test resources
  # ---------------------------------------------------------------------------

  defmodule SimplePkResource do
    @moduledoc false
    def __ash_scylla__(:secondary_indexes), do: []
    def __ash_scylla__(:table), do: "simple_pk_table"
    def __ash_scylla__(_), do: nil
  end

  defmodule SingleIndexResource do
    @moduledoc false
    def __ash_scylla__(:secondary_indexes),
      do: [%{columns: [:email], name: nil, options: []}]

    def __ash_scylla__(:table), do: "single_index_table"
    def __ash_scylla__(_), do: nil
  end

  defmodule MultiColumnIndexResource do
    @moduledoc false
    def __ash_scylla__(:secondary_indexes),
      do: [%{columns: [:name, :age], name: nil, options: []}]

    def __ash_scylla__(:table), do: "multi_col_index_table"
    def __ash_scylla__(_), do: nil
  end

  defmodule MultiIndexResource do
    @moduledoc false
    def __ash_scylla__(:secondary_indexes),
      do: [
        %{columns: [:email], name: nil, options: []},
        %{columns: [:status], name: nil, options: []},
        %{columns: [:created_at], name: nil, options: []}
      ]

    def __ash_scylla__(:table), do: "multi_index_table"
    def __ash_scylla__(_), do: nil
  end

  defmodule NoDslResource do
    @moduledoc false
    # Does not define __ash_scylla__/1
  end

  # ---------------------------------------------------------------------------
  # validate_filters/2 — single invalid column
  # ---------------------------------------------------------------------------

  describe "validate_filters/2 — single invalid column" do
    test "raises error for single non-indexed column on PK-only resource" do
      filters = [
        %{operator: :eq, left: %{name: :non_indexed}, right: %{value: "value"}}
      ]

      assert_raise AshScylla.Error, ~r/requires a secondary index/, fn ->
        FilterValidator.validate_filters(SimplePkResource, filters)
      end
    end

    test "error message includes the invalid column name" do
      filters = [
        %{operator: :eq, left: %{name: :bad_column}, right: %{value: "value"}}
      ]

      assert_raise AshScylla.Error, ~r/bad_column/, fn ->
        FilterValidator.validate_filters(SimplePkResource, filters)
      end
    end

    test "error message suggests adding secondary_index" do
      filters = [
        %{operator: :eq, left: %{name: :missing_col}, right: %{value: "value"}}
      ]

      assert_raise AshScylla.Error, ~r/secondary_index/, fn ->
        FilterValidator.validate_filters(SimplePkResource, filters)
      end
    end

    test "error message includes primary key info" do
      filters = [
        %{operator: :eq, left: %{name: :bad_col}, right: %{value: "value"}}
      ]

      assert_raise AshScylla.Error, ~r/primary key/, fn ->
        FilterValidator.validate_filters(SimplePkResource, filters)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # validate_filters/2 — multiple invalid columns
  # ---------------------------------------------------------------------------

  describe "validate_filters/2 — multiple invalid columns" do
    test "reports all invalid columns in a single error" do
      filters = [
        %{operator: :eq, left: %{name: :col_a}, right: %{value: "a"}},
        %{operator: :eq, left: %{name: :col_b}, right: %{value: "b"}}
      ]

      error =
        assert_raise AshScylla.Error, fn ->
          FilterValidator.validate_filters(SimplePkResource, filters)
        end

      assert error.message =~ "col_a"
      assert error.message =~ "col_b"
    end

    test "does not duplicate column names already in the filter list" do
      filters = [
        %{operator: :eq, left: %{name: :same_col}, right: %{value: "a"}},
        %{operator: :eq, left: %{name: :same_col}, right: %{value: "b"}}
      ]

      error =
        assert_raise AshScylla.Error, fn ->
          FilterValidator.validate_filters(SimplePkResource, filters)
        end

      # The column name appears in the filter list and in the suggestion.
      # Split gives n+1 segments for n occurrences.
      occurrences =
        error.message
        |> String.split("same_col")
        |> length()

      assert occurrences == 3
    end

    test "reports three invalid columns" do
      filters = [
        %{operator: :eq, left: %{name: :x}, right: %{value: 1}},
        %{operator: :eq, left: %{name: :y}, right: %{value: 2}},
        %{operator: :eq, left: %{name: :z}, right: %{value: 3}}
      ]

      error =
        assert_raise AshScylla.Error, fn ->
          FilterValidator.validate_filters(SimplePkResource, filters)
        end

      assert error.message =~ "x"
      assert error.message =~ "y"
      assert error.message =~ "z"
    end
  end

  # ---------------------------------------------------------------------------
  # validate_filters/2 — valid columns (happy path)
  # ---------------------------------------------------------------------------

  describe "validate_filters/2 — valid columns" do
    test "returns :ok for empty filter list" do
      assert FilterValidator.validate_filters(SimplePkResource, []) == :ok
    end

    test "returns :ok for PK column filter" do
      filters = [
        %{operator: :eq, left: %{name: :id}, right: %{value: "abc-123"}}
      ]

      assert FilterValidator.validate_filters(SimplePkResource, filters) == :ok
    end

    test "returns :ok for indexed column filter" do
      filters = [
        %{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}}
      ]

      assert FilterValidator.validate_filters(SingleIndexResource, filters) == :ok
    end

    test "returns :ok for mix of PK and indexed columns" do
      filters = [
        %{operator: :eq, left: %{name: :id}, right: %{value: "abc-123"}},
        %{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}}
      ]

      assert FilterValidator.validate_filters(SingleIndexResource, filters) == :ok
    end

    test "returns :ok for composite index columns" do
      filters = [
        %{operator: :eq, left: %{name: :name}, right: %{value: "John"}},
        %{operator: :eq, left: %{name: :age}, right: %{value: 30}}
      ]

      assert FilterValidator.validate_filters(MultiColumnIndexResource, filters) == :ok
    end

    test "returns :ok for all multiple indexed columns" do
      filters = [
        %{operator: :eq, left: %{name: :email}, right: %{value: "a@b.com"}},
        %{operator: :eq, left: %{name: :status}, right: %{value: "active"}},
        %{operator: :eq, left: %{name: :created_at}, right: %{value: "2024-01-01"}}
      ]

      assert FilterValidator.validate_filters(MultiIndexResource, filters) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # validate_filters/2 — nested expressions
  # ---------------------------------------------------------------------------

  describe "validate_filters/2 — nested expressions" do
    test "handles nested expression filters" do
      filters = [
        %{
          expression: %{
            operator: :eq,
            left: %{name: :non_indexed},
            right: %{value: "value"}
          }
        }
      ]

      assert_raise AshScylla.Error, ~r/non_indexed/, fn ->
        FilterValidator.validate_filters(SimplePkResource, filters)
      end
    end

    test "handles AND/OR composite filters with invalid column" do
      filters = [
        %{
          left: %{operator: :eq, left: %{name: :id}, right: %{value: "abc"}},
          right: %{operator: :eq, left: %{name: :non_indexed}, right: %{value: "x"}}
        }
      ]

      assert_raise AshScylla.Error, ~r/non_indexed/, fn ->
        FilterValidator.validate_filters(SimplePkResource, filters)
      end
    end

    test "handles deeply nested AND/OR with invalid column" do
      filters = [
        %{
          left: %{
            left: %{operator: :eq, left: %{name: :id}, right: %{value: "a"}},
            right: %{operator: :eq, left: %{name: :email}, right: %{value: "a@b.com"}}
          },
          right: %{operator: :eq, left: %{name: :non_indexed}, right: %{value: "x"}}
        }
      ]

      assert_raise AshScylla.Error, ~r/non_indexed/, fn ->
        FilterValidator.validate_filters(SingleIndexResource, filters)
      end
    end

    test "handles nested expression inside AND" do
      filters = [
        %{
          left: %{
            expression: %{
              operator: :eq,
              left: %{name: :non_indexed},
              right: %{value: "v"}
            }
          },
          right: %{operator: :eq, left: %{name: :id}, right: %{value: "abc"}}
        }
      ]

      assert_raise AshScylla.Error, ~r/non_indexed/, fn ->
        FilterValidator.validate_filters(SimplePkResource, filters)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # validate_filters/2 — resource without DSL
  # ---------------------------------------------------------------------------

  describe "validate_filters/2 — resource without DSL" do
    test "raises for non-PK column on resource without DSL" do
      filters = [
        %{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}}
      ]

      assert_raise AshScylla.Error, ~r/requires a secondary index/, fn ->
        FilterValidator.validate_filters(NoDslResource, filters)
      end
    end

    test "returns :ok for PK column on resource without DSL" do
      filters = [
        %{operator: :eq, left: %{name: :id}, right: %{value: "abc-123"}}
      ]

      assert FilterValidator.validate_filters(NoDslResource, filters) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # validate_in_filters/2
  # ---------------------------------------------------------------------------

  describe "validate_in_filters/2" do
    test "accepts IN filter on indexed column" do
      filters = [
        %{operator: :in, left: %{name: :email}, right: %{value: ["a@b.com", "c@d.com"]}}
      ]

      assert FilterValidator.validate_in_filters(SingleIndexResource, filters) == :ok
    end

    test "rejects IN filter on non-indexed column" do
      filters = [
        %{operator: :in, left: %{name: :non_indexed}, right: %{value: ["a", "b"]}}
      ]

      assert_raise AshScylla.Error, ~r/requires.*secondary index/, fn ->
        FilterValidator.validate_in_filters(SingleIndexResource, filters)
      end
    end

    test "rejects empty IN filter list" do
      filters = [
        %{operator: :in, left: %{name: :email}, right: %{value: []}}
      ]

      assert_raise AshScylla.Error, ~r/empty value list/, fn ->
        FilterValidator.validate_in_filters(SingleIndexResource, filters)
      end
    end

    test "accepts single-element IN filter" do
      filters = [
        %{operator: :in, left: %{name: :email}, right: %{value: ["only@one.com"]}}
      ]

      assert FilterValidator.validate_in_filters(SingleIndexResource, filters) == :ok
    end

    test "accepts IN filter on PK column" do
      filters = [
        %{operator: :in, left: %{name: :id}, right: %{value: ["a", "b", "c"]}}
      ]

      assert FilterValidator.validate_in_filters(SimplePkResource, filters) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # validate_aggregate_filters/2
  # ---------------------------------------------------------------------------

  describe "validate_aggregate_filters/2" do
    test "accepts count aggregate" do
      aggregates = [%{type: :count, name: :total}]
      assert FilterValidator.validate_aggregate_filters(SimplePkResource, aggregates) == :ok
    end

    test "accepts count aggregate on indexed field" do
      aggregates = [%{type: :count, name: :email_count, field: :email}]
      assert FilterValidator.validate_aggregate_filters(SingleIndexResource, aggregates) == :ok
    end

    test "rejects aggregate on non-indexed field" do
      aggregates = [%{type: :count, name: :bad_count, field: :non_indexed}]

      assert_raise AshScylla.Error, fn ->
        FilterValidator.validate_aggregate_filters(SimplePkResource, aggregates)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # validate_calculation_filters/2
  # ---------------------------------------------------------------------------

  describe "validate_calculation_filters/2" do
    test "accepts calculation without field dependency" do
      calculations = [%{name: :my_calc, type: :string, expression: "name"}]
      assert FilterValidator.validate_calculation_filters(SimplePkResource, calculations) == :ok
    end

    test "accepts calculation referencing indexed field" do
      calculations = [%{name: :email_calc, type: :string, expression: "email"}]

      assert FilterValidator.validate_calculation_filters(SingleIndexResource, calculations) ==
               :ok
    end
  end

  # ---------------------------------------------------------------------------
  # validate_base_filter/1
  # ---------------------------------------------------------------------------

  describe "validate_base_filter/1" do
    test "accepts resource without base_filter" do
      assert FilterValidator.validate_base_filter(SimplePkResource) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # validate_relationship_filters/2
  # ---------------------------------------------------------------------------

  describe "validate_relationship_filters/2" do
    test "accepts empty relationship filters" do
      assert FilterValidator.validate_relationship_filters(SimplePkResource, []) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # validate_exists_filters/2
  # ---------------------------------------------------------------------------

  describe "validate_exists_filters/2" do
    test "accepts empty exists filters" do
      assert FilterValidator.validate_exists_filters(SimplePkResource, []) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # validate_all/2 — comprehensive validation
  # ---------------------------------------------------------------------------

  describe "validate_all/2 — comprehensive validation" do
    test "validates filters, aggregates, and calculations together" do
      filters = [
        %{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}}
      ]

      aggregates = [%{type: :count, name: :total_count}]
      calculations = [%{name: :my_calc, type: :string, expression: "name"}]

      assert FilterValidator.validate_all(SingleIndexResource, filters,
               aggregates: aggregates,
               calculations: calculations,
               validate_base: false,
               validate_relationships: false
             ) == :ok
    end

    test "rejects when any filter column is invalid" do
      filters = [
        %{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}},
        %{operator: :eq, left: %{name: :non_indexed}, right: %{value: "x"}}
      ]

      assert_raise AshScylla.Error, ~r/non_indexed/, fn ->
        FilterValidator.validate_all(SingleIndexResource, filters,
          validate_base: false,
          validate_relationships: false
        )
      end
    end

    test "validates base_filter when requested" do
      assert FilterValidator.validate_all(SimplePkResource, [],
               validate_base: true,
               validate_relationships: false
             ) == :ok
    end

    test "validates relationships when requested" do
      assert FilterValidator.validate_all(SimplePkResource, [],
               validate_base: false,
               validate_relationships: true
             ) == :ok
    end

    test "validates all flags enabled together" do
      filters = [
        %{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}}
      ]

      assert FilterValidator.validate_all(SingleIndexResource, filters,
               aggregates: [%{type: :count, name: :cnt}],
               calculations: [%{name: :calc, type: :string, expression: "name"}],
               validate_base: true,
               validate_relationships: false
             ) == :ok
    end

    test "validates all flags including relationships when no relationship filters" do
      filters = [
        %{operator: :eq, left: %{name: :id}, right: %{value: "abc-123"}}
      ]

      assert FilterValidator.validate_all(SingleIndexResource, filters,
               aggregates: [%{type: :count, name: :cnt}],
               calculations: [%{name: :calc, type: :string, expression: "name"}],
               validate_base: true,
               validate_relationships: false
             ) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # queryable_columns/1
  # ---------------------------------------------------------------------------

  describe "queryable_columns/1" do
    test "returns PK columns for resource with no indexes" do
      columns = FilterValidator.queryable_columns(SimplePkResource)
      assert :id in columns
    end

    test "returns PK and indexed columns" do
      columns = FilterValidator.queryable_columns(SingleIndexResource)
      assert :id in columns
      assert :email in columns
    end

    test "returns all columns from multi-column index" do
      columns = FilterValidator.queryable_columns(MultiColumnIndexResource)
      assert :id in columns
      assert :name in columns
      assert :age in columns
    end

    test "returns all columns from multiple indexes" do
      columns = FilterValidator.queryable_columns(MultiIndexResource)
      assert :id in columns
      assert :email in columns
      assert :status in columns
      assert :created_at in columns
    end

    test "returns PK columns for resource without DSL" do
      columns = FilterValidator.queryable_columns(NoDslResource)
      assert :id in columns
    end
  end
end
