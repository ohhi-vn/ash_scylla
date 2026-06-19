defmodule AshScylla.FilterValidatorEdgeTest do
  @moduledoc """
  Additional tests for FilterValidator to cover edge cases.
  Covers: Issue #20 (FilterValidator raises on first invalid filter instead of collecting all errors)
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.FilterValidator

  defmodule MultiIndexResource do
    @moduledoc false
    def __ash_scylla__(:secondary_indexes),
      do: [
        %{columns: [:email_col], name: nil, options: []},
        %{columns: [:name_col], name: nil, options: []},
        %{columns: [:status_col], name: nil, options: []}
      ]

    def __ash_scylla__(:table), do: "multi_index_resource"
    def __ash_scylla__(_), do: nil
  end

  describe "validate_filters/2 — comprehensive scenarios" do
    test "validates filters on all indexed columns" do
      filters = [
        %{operator: :eq, left: %{name: :email_col}, right: %{value: "test@example.com"}},
        %{operator: :eq, left: %{name: :name_col}, right: %{value: "John"}},
        %{operator: :eq, left: %{name: :status_col}, right: %{value: "active"}}
      ]

      assert FilterValidator.validate_filters(MultiIndexResource, filters) == :ok
    end

    test "raises error for single non-indexed column" do
      filters = [
        %{operator: :eq, left: %{name: :non_indexed}, right: %{value: "value"}}
      ]

      assert_raise AshScylla.Error, ~r/requires a secondary index/, fn ->
        FilterValidator.validate_filters(MultiIndexResource, filters)
      end
    end

    test "validates empty filter list" do
      assert FilterValidator.validate_filters(MultiIndexResource, []) == :ok
    end

    test "handles complex nested filter expressions" do
      filters = [
        %{
          left: %{operator: :eq, left: %{name: :email_col}, right: %{value: "test@example.com"}},
          right: %{operator: :eq, left: %{name: :name_col}, right: %{value: "John"}}
        }
      ]

      assert FilterValidator.validate_filters(MultiIndexResource, filters) == :ok
    end
  end

  describe "validate_all/3 — comprehensive validation" do
    test "validates filters, aggregates, and calculations together" do
      filters = [
        %{operator: :eq, left: %{name: :email_col}, right: %{value: "test@example.com"}}
      ]

      aggregates = [
        %{type: :count, name: :total_count}
      ]

      assert FilterValidator.validate_all(MultiIndexResource, filters,
               aggregates: aggregates,
               validate_base: false,
               validate_relationships: false
             ) == :ok
    end

    test "validates IN filters on indexed columns" do
      filters = [
        %{operator: :in, left: %{name: :email_col}, right: %{value: ["a@b.com", "c@d.com"]}}
      ]

      assert FilterValidator.validate_all(MultiIndexResource, filters,
               validate_base: false,
               validate_in: true,
               validate_relationships: false
             ) == :ok
    end

    test "rejects IN filter on non-indexed column" do
      filters = [
        %{operator: :in, left: %{name: :non_indexed}, right: %{value: ["a", "b"]}}
      ]

      assert_raise AshScylla.Error, ~r/requires.*secondary index/, fn ->
        FilterValidator.validate_all(MultiIndexResource, filters,
          validate_base: false,
          validate_in: true,
          validate_relationships: false
        )
      end
    end

    test "rejects empty IN filter list" do
      filters = [
        %{operator: :in, left: %{name: :email_col}, right: %{value: []}}
      ]

      assert_raise AshScylla.Error, ~r/empty value list/, fn ->
        FilterValidator.validate_all(MultiIndexResource, filters,
          validate_base: false,
          validate_in: true,
          validate_relationships: false
        )
      end
    end
  end

  describe "queryable_columns/1" do
    test "returns all PK and indexed columns" do
      columns = FilterValidator.queryable_columns(MultiIndexResource)
      assert :id in columns
      assert :email_col in columns
      assert :name_col in columns
      assert :status_col in columns
    end
  end
end
