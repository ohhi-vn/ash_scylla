defmodule AshScylla.DataLayer.FilterValidatorTest do
  @moduledoc """
  Tests for AshScylla.DataLayer.FilterValidator.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.FilterValidator

  # ---------------------------------------------------------------------------
  # Test resources (inline modules with __ash_scylla__ callbacks)
  # ---------------------------------------------------------------------------

  defmodule ResourceWithPKAndIndexes do
    @moduledoc false
    def __ash_scylla__(:secondary_indexes),
      do: [
        %{columns: [:email], name: nil, options: []},
        %{columns: [:name, :age], name: nil, options: []}
      ]

    def __ash_scylla__(:table), do: "test_resource"
    def __ash_scylla__(_), do: nil
  end

  defmodule ResourceWithPKOnly do
    @moduledoc false
    def __ash_scylla__(:secondary_indexes), do: []
    def __ash_scylla__(:table), do: "test_resource"
    def __ash_scylla__(_), do: nil
  end

  defmodule ResourceWithNoDSL do
    @moduledoc false
    # Does not define __ash_scylla__/1 at all
  end

  # ---------------------------------------------------------------------------
  # validate_filters/2
  # ---------------------------------------------------------------------------

  describe "validate_filters/2" do
    test "returns :ok when all filter columns are primary keys" do
      filters = [
        %{operator: :eq, left: %{name: :id}, right: %{value: "abc-123"}}
      ]

      assert FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters) == :ok
    end

    test "returns :ok when all filter columns have secondary indexes" do
      filters = [
        %{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}}
      ]

      assert FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters) == :ok
    end

    test "returns :ok for mix of PK and indexed columns" do
      filters = [
        %{operator: :eq, left: %{name: :id}, right: %{value: "abc-123"}},
        %{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}}
      ]

      assert FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters) == :ok
    end

    test "returns :ok for composite index columns" do
      filters = [
        %{operator: :eq, left: %{name: :name}, right: %{value: "John"}},
        %{operator: :eq, left: %{name: :age}, right: %{value: 30}}
      ]

      assert FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters) == :ok
    end

    test "returns :ok for empty filter list" do
      assert FilterValidator.validate_filters(ResourceWithPKAndIndexes, []) == :ok
    end

    test "raises AshScylla.Error for non-indexed, non-PK column" do
      filters = [
        %{operator: :eq, left: %{name: :non_indexed_col}, right: %{value: "value"}}
      ]

      assert_raise AshScylla.Error, ~r/requires a secondary index/, fn ->
        FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters)
      end
    end

    test "error message includes the column name" do
      filters = [
        %{operator: :eq, left: %{name: :unknown_col}, right: %{value: "value"}}
      ]

      assert_raise AshScylla.Error, ~r/unknown_col/, fn ->
        FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters)
      end
    end

    test "error message suggests adding secondary_index" do
      filters = [
        %{operator: :eq, left: %{name: :missing_col}, right: %{value: "value"}}
      ]

      assert_raise AshScylla.Error, ~r/secondary_index/, fn ->
        FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters)
      end
    end

    test "error message includes primary key info" do
      filters = [
        %{operator: :eq, left: %{name: :bad_col}, right: %{value: "value"}}
      ]

      assert_raise AshScylla.Error, ~r/primary key/, fn ->
        FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters)
      end
    end

    test "raises for resource with no secondary indexes and non-PK filter" do
      filters = [
        %{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}}
      ]

      assert_raise AshScylla.Error, ~r/requires a secondary index/, fn ->
        FilterValidator.validate_filters(ResourceWithPKOnly, filters)
      end
    end

    test "raises for resource without DSL when filtering on non-PK column" do
      filters = [
        %{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}}
      ]

      assert_raise AshScylla.Error, ~r/requires a secondary index/, fn ->
        FilterValidator.validate_filters(ResourceWithNoDSL, filters)
      end
    end

    test "validates multiple non-indexed columns and reports all of them" do
      filters = [
        %{operator: :eq, left: %{name: :col_a}, right: %{value: "a"}},
        %{operator: :eq, left: %{name: :col_b}, right: %{value: "b"}}
      ]

      error =
        assert_raise AshScylla.Error, fn ->
          FilterValidator.validate_filters(ResourceWithPKOnly, filters)
        end

      assert error.message =~ "col_a"
      assert error.message =~ "col_b"
    end

    test "does not duplicate column names in error message" do
      filters = [
        %{operator: :eq, left: %{name: :same_col}, right: %{value: "a"}},
        %{operator: :eq, left: %{name: :same_col}, right: %{value: "b"}}
      ]

      error =
        assert_raise AshScylla.Error, fn ->
          FilterValidator.validate_filters(ResourceWithPKOnly, filters)
        end

      # The column name appears in the filter list and in the suggestion.
      # Split gives n+1 segments for n occurrences.
      occurrences =
        error.message
        |> String.split("same_col")
        |> length()

      assert occurrences == 3
    end

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
        FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters)
      end
    end

    test "handles AND/OR composite filters" do
      filters = [
        %{
          left: %{operator: :eq, left: %{name: :id}, right: %{value: "abc"}},
          right: %{operator: :eq, left: %{name: :non_indexed}, right: %{value: "x"}}
        }
      ]

      assert_raise AshScylla.Error, ~r/non_indexed/, fn ->
        FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters)
      end
    end

    test "validates contains(name, value) function call with indexed column passes" do
      filters = [
        %{name: :contains, args: [%{name: :name}, %{value: "john"}]}
      ]

      assert FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters) == :ok
    end

    test "validates contains(col, value) with non-indexed column raises" do
      filters = [
        %{name: :contains, args: [%{name: :non_indexed_col}, %{value: "val"}]}
      ]

      assert_raise AshScylla.Error, ~r/non_indexed_col/, fn ->
        FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters)
      end
    end

    test "validates starts_with(name, value) function call with indexed column passes" do
      filters = [
        %{name: :starts_with, args: [%{name: :name}, %{value: "jo"}]}
      ]

      assert FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters) == :ok
    end

    test "validates ends_with(email, value) function call with indexed column passes" do
      filters = [
        %{name: :ends_with, args: [%{name: :email}, %{value: ".com"}]}
      ]

      assert FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters) == :ok
    end

    test "validates contains() with non-indexed column in secondary index scan resource raises" do
      filters = [
        %{name: :contains, args: [%{name: :email}, %{value: "test"}]}
      ]

      assert_raise AshScylla.Error, ~r/requires a secondary index/, fn ->
        FilterValidator.validate_filters(ResourceWithPKOnly, filters)
      end
    end

    test "validates AND of contains() on indexed column + eq on PK passes" do
      filters = [
        %{
          left: %{name: :contains, args: [%{name: :name}, %{value: "john"}]},
          right: %{operator: :eq, left: %{name: :id}, right: %{value: "abc"}}
        }
      ]

      assert FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters) == :ok
    end

    test "extracts columns from contains() with Ash.Query.Call struct" do
      filters = [
        %{__struct__: Ash.Query.Call, name: :contains, args: [%{name: :name}, %{value: "john"}]}
      ]

      assert FilterValidator.validate_filters(ResourceWithPKAndIndexes, filters) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # queryable_columns/1
  # ---------------------------------------------------------------------------

  describe "queryable_columns/1" do
    test "returns indexed columns for a resource with indexes" do
      columns = FilterValidator.queryable_columns(ResourceWithPKAndIndexes)
      assert :email in columns
      assert :name in columns
      assert :age in columns
    end

    test "returns PK columns for resource with no indexes" do
      columns = FilterValidator.queryable_columns(ResourceWithPKOnly)
      assert :id in columns
    end

    test "returns PK columns for resource without DSL" do
      columns = FilterValidator.queryable_columns(ResourceWithNoDSL)
      assert :id in columns
    end
  end
end
