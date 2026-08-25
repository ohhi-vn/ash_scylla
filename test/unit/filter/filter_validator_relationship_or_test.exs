defmodule AshScylla.FilterValidatorRelationshipOrTest do
  @moduledoc """
  Covers FilterValidator relationship-filter target validation, OR-expression
  handling, function-call column extraction, and base_filter validation.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.FilterValidator

  defmodule FvxNoRelationshipsResource do
    def __ash_scylla__(:secondary_indexes), do: []
    def __ash_scylla__(_), do: nil
  end

  defmodule FvxBaseFilterListResource do
    def __ash_scylla__(:secondary_indexes), do: []

    def __ash_scylla__(:base_filter),
      do: [%{operator: :eq, left: %{name: :id}, right: %{value: "x"}}]

    def __ash_scylla__(_), do: nil
  end

  defmodule FvxBaseFilterEmptyResource do
    def __ash_scylla__(:secondary_indexes), do: []
    def __ash_scylla__(:base_filter), do: []
    def __ash_scylla__(_), do: nil
  end

  describe "validate_base_filter/1" do
    test "validates each filter in a list base_filter" do
      assert FilterValidator.validate_base_filter(FvxBaseFilterListResource) == :ok
    end

    test "raises when a list base_filter references an unknown column" do
      filters = [%{operator: :eq, left: %{name: :nope}, right: %{value: 1}}]

      assert_raise AshScylla.Error, ~r/requires a secondary index/, fn ->
        FilterValidator.validate_filters(FvxBaseFilterListResource, filters)
      end
    end

    test "returns ok for an empty list base_filter" do
      assert FilterValidator.validate_base_filter(FvxBaseFilterEmptyResource) == :ok
    end
  end

  describe "validate_or_filters/1" do
    test "accepts same-field OR with operator key" do
      filters = [
        %{
          op: :or,
          left: %{operator: :eq, left: %{name: :status}, right: %{value: "a"}},
          right: %{operator: :eq, left: %{name: :status}, right: %{value: "b"}}
        }
      ]

      assert FilterValidator.validate_or_filters(filters) == :ok
    end

    test "accepts same-field OR with op key on both sides" do
      filters = [
        %{
          op: :or,
          left: %{op: :eq, left: %{name: :status}, right: %{value: "a"}},
          right: %{op: :eq, left: %{name: :status}, right: %{value: "b"}}
        }
      ]

      assert FilterValidator.validate_or_filters(filters) == :ok
    end

    test "rejects OR across different fields" do
      filters = [
        %{
          op: :or,
          left: %{operator: :eq, left: %{name: :status}, right: %{value: "a"}},
          right: %{operator: :eq, left: %{name: :email}, right: %{value: "b"}}
        }
      ]

      assert_raise AshScylla.Error, ~r/CQL does not support OR across different fields/, fn ->
        FilterValidator.validate_or_filters(filters)
      end
    end

    test "unwraps expression-wrapped operands before comparison" do
      filters = [
        %{
          op: :or,
          left: %{expression: %{operator: :eq, left: %{name: :status}, right: %{value: "a"}}},
          right: %{expression: %{operator: :eq, left: %{name: :status}, right: %{value: "b"}}}
        }
      ]

      assert FilterValidator.validate_or_filters(filters) == :ok
    end

    test "recurses into wrapped expressions" do
      filters = [%{expression: %{op: :or, left: %{name: :a}, right: %{name: :b}}}]

      assert_raise AshScylla.Error, ~r/CQL does not support OR/, fn ->
        FilterValidator.validate_or_filters(filters)
      end
    end
  end

  describe "column extraction from function-style filters" do
    test "extracts columns from __function__? structs" do
      filters = [
        %{__function__?: true, arguments: [%{left: %{name: :id}}, %{value: "query"}]}
      ]

      assert FilterValidator.validate_filters(FvxBaseFilterEmptyResource, filters) == :ok
    end

    test "extracts columns from contains/starts_with/ends_with argument maps" do
      filters = [
        %{name: :contains, arguments: [%{left: %{name: :id}}, %{value: "x"}]},
        %{name: :starts_with, arguments: [%{left: %{name: :id}}]},
        %{name: :ends_with, arguments: [%{left: %{name: :id}}]}
      ]

      assert FilterValidator.validate_filters(FvxBaseFilterEmptyResource, filters) == :ok
    end

    test "extracts columns from bare left-name filters" do
      assert FilterValidator.validate_filters(FvxBaseFilterEmptyResource, [
               %{left: %{name: :id}}
             ]) == :ok
    end

    test "extracts columns from generic name+args calls" do
      assert FilterValidator.validate_filters(FvxBaseFilterEmptyResource, [
               %{name: :trim, args: [%{left: %{name: :id}}]}
             ]) == :ok
    end

    test "raises when extracted column is not queryable" do
      assert_raise AshScylla.Error, ~r/requires a secondary index/, fn ->
        FilterValidator.validate_filters(FvxBaseFilterEmptyResource, [
          %{name: :contains, arguments: [%{left: %{name: :unknown_col}}, %{value: "x"}]}
        ])
      end
    end
  end

  describe "validate_exists_filters/2 with wrapped expressions" do
    test "recurses into expression-wrapped exists filters" do
      filters = [%{expression: %{operator: :exists, left: %{name: :id}}}]

      assert_raise AshScylla.Error, ~r/EXISTS filter references unknown column/, fn ->
        FilterValidator.validate_exists_filters(FvxNoRelationshipsResource, filters)
      end
    end
  end

  describe "validate_relationship_filters/2" do
    test "raises for a relationship path on a resource without relationships" do
      filters = [%{path: [:deal, :id], operator: :eq, value: "x"}]

      assert_raise AshScylla.Error,
                   ~r/references relationship `:deal` which is not defined/,
                   fn ->
                     FilterValidator.validate_relationship_filters(
                       FvxNoRelationshipsResource,
                       filters
                     )
                   end
    end

    test "falls back to extract_filter_path when no :path key is present" do
      filter = %{operator: :eq, left: %{name: :deal}, right: %{value: "x"}}

      assert_raise AshScylla.Error,
                   ~r/references relationship `:deal` which is not defined/,
                   fn ->
                     FilterValidator.validate_relationship_filters(FvxNoRelationshipsResource, [
                       filter
                     ])
                   end
    end

    test "extract_filter_path falls back to empty for opaque filters" do
      filter = %{operator: :is_nil, right: %{value: true}}

      assert FilterValidator.validate_relationship_filters(
               FvxNoRelationshipsResource,
               [filter]
             ) == :ok
    end
  end

  describe "validate_calculation_filters/2 expression unwrapping" do
    test "unwraps nested expression maps" do
      calculations = [%{name: :calc, type: :string, expression: %{expression: %{name: :id}}}]

      assert_raise AshScylla.Error, ~r/references unknown column/, fn ->
        FilterValidator.validate_calculation_filters(FvxBaseFilterEmptyResource, calculations)
      end
    end

    test "ignores non-reference expressions" do
      calculations = [%{name: :calc, type: :string, expression: %{literal: 1}}]

      assert FilterValidator.validate_calculation_filters(
               FvxBaseFilterEmptyResource,
               calculations
             ) == :ok
    end
  end
end
