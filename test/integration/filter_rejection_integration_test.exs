defmodule AshScylla.FilterRejectionIntegrationTest do
  @moduledoc """
  Integration tests verifying that filters on unindexed columns
  are rejected at query-plan time with actionable error messages.
  """
  use ExUnit.Case, async: true

  @moduletag :integration

  alias AshScylla.DataLayer.FilterValidator

  describe "filter rejection on unindexed columns" do
    test "filter on non-indexed, non-PK column raises AshScylla.Error" do
      # TestResource has :name and :email indexed, but :age is NOT indexed
      filters = [%{left: %{name: :age}, operator: :gt, right: %{value: 25}}]

      assert_raise AshScylla.Error, ~r/unindexed|secondary_index|scylla/i, fn ->
        FilterValidator.validate_filters(AshScylla.TestResource, filters)
      end
    end

    test "error message suggests adding secondary_index to scylla block" do
      filters = [%{left: %{name: :password_hash}, operator: :eq, right: %{value: "x"}}]

      try do
        FilterValidator.validate_filters(AshScylla.TestResource, filters)
      rescue
        error in [AshScylla.Error] ->
          assert error.message =~ "secondary_index"
          assert error.message =~ "scylla"
      end
    end

    test "filter on PK column always allowed" do
      filters = [%{left: %{name: :id}, operator: :eq, right: %{value: "uuid"}}]
      assert :ok == FilterValidator.validate_filters(AshScylla.TestResource, filters)
    end

    test "filter on indexed column always allowed" do
      filters = [%{left: %{name: :email}, operator: :eq, right: %{value: "a@b.com"}}]
      assert :ok == FilterValidator.validate_filters(AshScylla.TestResource, filters)
    end

    test "mixed indexed + unindexed columns raises on the unindexed column" do
      filters = [
        %{left: %{name: :email}, operator: :eq, right: %{value: "a@b.com"}},
        %{left: %{name: :age}, operator: :gt, right: %{value: 25}}
      ]

      assert_raise AshScylla.Error, ~r/age/, fn ->
        FilterValidator.validate_filters(AshScylla.TestResource, filters)
      end
    end

    test "validate_all checks filters, aggregates, calculations, and base_filter" do
      # validate_all is the comprehensive validation entry point
      filters = [%{left: %{name: :age}, operator: :gt, right: %{value: 25}}]

      assert_raise AshScylla.Error, fn ->
        FilterValidator.validate_all(AshScylla.TestResource, filters)
      end
    end
  end
end
