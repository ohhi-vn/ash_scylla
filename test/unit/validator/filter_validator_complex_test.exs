defmodule AshScylla.FilterValidatorComplexTest do
  @moduledoc """
  Complex validation scenarios for AshScylla.DataLayer.FilterValidator —
  aggregate filters, calculation filters, relationship filters,
  EXISTS, IN, base_filter, and the comprehensive validate_all/1.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.FilterValidator

  # ---------------------------------------------------------------------------
  # Test resources
  # ---------------------------------------------------------------------------

  defmodule UserResource do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    ash_scylla do
      table("users")
      keyspace("ash_scylla_test")
      secondary_index(:email)
      secondary_index(:status)
      secondary_index(:org_id)
      base_filter(%{name: :org_id, op: :eq, right: %{value: "org-1"}})
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:email, :string, public?: true)
      attribute(:status, :string, public?: true)
      attribute(:age, :integer, public?: true)
      attribute(:org_id, :string, public?: true)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule AuthorResource do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    ash_scylla do
      table("authors")
      keyspace("ash_scylla_test")
      secondary_index(:name)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:email, :string, public?: true)
    end

    actions do
      defaults([:create, :read])
    end
  end

  defmodule StrictResource do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    ash_scylla do
      table("strict_resource")
      keyspace("ash_scylla_test")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:create, :read])
    end
  end

  # ---------------------------------------------------------------------------
  # validate_filters/1 — composite primary key scenarios
  # ---------------------------------------------------------------------------

  describe "validate_filters/1 with composite primary key" do
    test "accepts filter on partition key" do
      assert :ok =
               FilterValidator.validate_filters(UserResource, [
                 %{operator: :eq, left: %{name: :id}, right: %{value: "abc"}}
               ])
    end

    test "accepts filter on indexed column" do
      assert :ok =
               FilterValidator.validate_filters(UserResource, [
                 %{operator: :eq, left: %{name: :email}, right: %{value: "a@b.co"}}
               ])
    end

    test "rejects filter on non-indexed column" do
      assert_raise AshScylla.Error, ~r/requires a secondary index/, fn ->
        FilterValidator.validate_filters(UserResource, [
          %{operator: :eq, left: %{name: :age}, right: %{value: 30}}
        ])
      end
    end

    test "rejects when mixing indexed and non-indexed columns" do
      assert_raise AshScylla.Error, ~r/\[age\] requires a secondary index/, fn ->
        FilterValidator.validate_filters(UserResource, [
          %{operator: :eq, left: %{name: :email}, right: %{value: "a@b.co"}},
          %{operator: :gt, left: %{name: :age}, right: %{value: 30}}
        ])
      end
    end

    test "accepts empty filter list" do
      assert :ok = FilterValidator.validate_filters(UserResource, [])
    end

    test "error message includes pk and indexed columns" do
      assert_raise AshScylla.Error, ~r/primary key \[id\]/, fn ->
        FilterValidator.validate_filters(UserResource, [
          %{operator: :eq, left: %{name: :age}, right: %{value: 30}}
        ])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # validate_aggregate_filters/2
  # ---------------------------------------------------------------------------

  describe "validate_aggregate_filters/2" do
    test "accepts count without field" do
      assert :ok =
               FilterValidator.validate_aggregate_filters(UserResource, [
                 %{type: :count, name: :total_users}
               ])
    end

    test "accepts count with field" do
      assert :ok =
               FilterValidator.validate_aggregate_filters(UserResource, [
                 %{type: :count, name: :active_users, field: :email}
               ])
    end

    test "accepts sum with indexed field" do
      assert :ok =
               FilterValidator.validate_aggregate_filters(UserResource, [
                 %{type: :sum, name: :total, field: :email}
               ])
    end

    test "rejects unsupported aggregate type" do
      assert_raise AshScylla.Error, ~r/Unsupported aggregate type/, fn ->
        FilterValidator.validate_aggregate_filters(UserResource, [
          %{type: :median, name: :median_age, field: :age}
        ])
      end
    end

    test "rejects aggregate on non-indexed field" do
      assert_raise AshScylla.Error, ~r/references field.*not a primary key or indexed/, fn ->
        FilterValidator.validate_aggregate_filters(StrictResource, [
          %{type: :sum, name: :total, field: :name}
        ])
      end
    end

    test "accepts multiple aggregates" do
      assert :ok =
               FilterValidator.validate_aggregate_filters(UserResource, [
                 %{type: :count, name: :total},
                 %{type: :avg, name: :avg_email, field: :email},
                 %{type: :max, name: :max_email, field: :email}
               ])
    end

    test "rejects count on non-indexed field" do
      assert_raise AshScylla.Error, ~r/references field.*not a primary key or indexed/, fn ->
        FilterValidator.validate_aggregate_filters(StrictResource, [
          %{type: :count, name: :total, field: :name}
        ])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # validate_calculation_filters/2
  # ---------------------------------------------------------------------------

  describe "validate_calculation_filters/2" do
    test "accepts calculation with valid expression" do
      assert :ok =
               FilterValidator.validate_calculation_filters(UserResource, [
                 %{
                   name: :upper_name,
                   type: :string,
                   expression: %{name: :name}
                 }
               ])
    end

    test "rejects calculation with unknown column" do
      assert_raise AshScylla.Error, ~r/references unknown column/, fn ->
        FilterValidator.validate_calculation_filters(UserResource, [
          %{
            name: :calc,
            type: :string,
            expression: %{name: :nonexistent}
          }
        ])
      end
    end

    test "rejects calculation with unloadable module" do
      assert_raise AshScylla.Error, ~r/references module.*could not be loaded/, fn ->
        FilterValidator.validate_calculation_filters(UserResource, [
          %{
            name: :calc,
            type: :string,
            module: SomeModule.That.Does.Not.Exist
          }
        ])
      end
    end

    test "accepts calculation with nested expression" do
      assert :ok =
               FilterValidator.validate_calculation_filters(UserResource, [
                 %{
                   name: :calc,
                   type: :string,
                   expression: %{
                     name: :name,
                     left: %{name: :name},
                     right: %{name: :email}
                   }
                 }
               ])
    end

    test "rejects nested expression with unknown column" do
      assert_raise AshScylla.Error, ~r/references unknown column/, fn ->
        FilterValidator.validate_calculation_filters(UserResource, [
          %{
            name: :calc,
            type: :string,
            expression: %{
              left: %{name: :name},
              right: %{name: :nonexistent}
            }
          }
        ])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # validate_relationship_filters/2
  # ---------------------------------------------------------------------------

  describe "validate_relationship_filters/2" do
    test "accepts empty filter list" do
      assert :ok = FilterValidator.validate_relationship_filters(UserResource, [])
    end

    test "accepts filter with no recognizable path" do
      # Filters with no :path key and no recognizable left/right names
      # fall through to the catch-all
      assert :ok =
               FilterValidator.validate_relationship_filters(UserResource, [
                 %{op: :and, left: :something, right: :other}
               ])
    end

    test "rejects filter with unknown relationship" do
      assert_raise AshScylla.Error, ~r/relationship.*not defined/, fn ->
        FilterValidator.validate_relationship_filters(UserResource, [
          %{path: [:nonexistent, :name], op: :eq, value: "Alice"}
        ])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # validate_exists_filters/2
  # ---------------------------------------------------------------------------

  describe "validate_exists_filters/2" do
    test "accepts exists on valid column" do
      assert :ok =
               FilterValidator.validate_exists_filters(UserResource, [
                 %{operator: :exists, left: %{name: :email}}
               ])
    end

    test "rejects exists on unknown column" do
      assert_raise AshScylla.Error, ~r/EXISTS filter references unknown column/, fn ->
        FilterValidator.validate_exists_filters(UserResource, [
          %{operator: :exists, left: %{name: :nonexistent}}
        ])
      end
    end

    test "handles nested expression" do
      assert :ok =
               FilterValidator.validate_exists_filters(UserResource, [
                 %{
                   left: %{operator: :exists, left: %{name: :email}},
                   right: %{operator: :exists, left: %{name: :name}}
                 }
               ])
    end
  end

  # ---------------------------------------------------------------------------
  # validate_in_filters/2
  # ---------------------------------------------------------------------------

  describe "validate_in_filters/2" do
    test "accepts IN on indexed column with non-empty list" do
      assert :ok =
               FilterValidator.validate_in_filters(UserResource, [
                 %{operator: :in, left: %{name: :email}, right: %{value: ["a@b.co", "c@d.co"]}}
               ])
    end

    test "rejects IN on non-indexed column" do
      assert_raise AshScylla.Error, ~r/requires the column to be part of the primary key/, fn ->
        FilterValidator.validate_in_filters(UserResource, [
          %{operator: :in, left: %{name: :age}, right: %{value: [30, 40]}}
        ])
      end
    end

    test "rejects IN with empty value list" do
      assert_raise AshScylla.Error, ~r/empty value list/, fn ->
        FilterValidator.validate_in_filters(UserResource, [
          %{operator: :in, left: %{name: :email}, right: %{value: []}}
        ])
      end
    end

    test "accepts IN on primary key" do
      assert :ok =
               FilterValidator.validate_in_filters(UserResource, [
                 %{operator: :in, left: %{name: :id}, right: %{value: ["abc", "def"]}}
               ])
    end

    test "handles nested expression" do
      assert :ok =
               FilterValidator.validate_in_filters(UserResource, [
                 %{
                   left: %{operator: :in, left: %{name: :email}, right: %{value: ["a@b.co"]}},
                   right: %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
                 }
               ])
    end
  end

  # ---------------------------------------------------------------------------
  # validate_base_filter/1
  # ---------------------------------------------------------------------------

  describe "validate_base_filter/1" do
    test "validates base_filter on resource with indexed column" do
      assert :ok = FilterValidator.validate_base_filter(UserResource)
    end

    test "returns ok for resource without base_filter" do
      assert :ok = FilterValidator.validate_base_filter(StrictResource)
    end
  end

  # ---------------------------------------------------------------------------
  # queryable_columns/1
  # ---------------------------------------------------------------------------

  describe "queryable_columns/1" do
    test "returns pk + indexed columns" do
      cols = FilterValidator.queryable_columns(UserResource)
      assert :id in cols
      assert :email in cols
      assert :status in cols
      assert :org_id in cols
      refute :age in cols
    end

    test "returns only pk for resource without indexes" do
      cols = FilterValidator.queryable_columns(StrictResource)
      assert cols == [:id]
    end
  end

  # ---------------------------------------------------------------------------
  # validate_all/2
  # ---------------------------------------------------------------------------

  describe "validate_all/2" do
    test "runs all validators with default opts" do
      # Use validate_relationships: false to avoid relationship path inference
      # (filters with left: %{name: _} are treated as potential relationship paths)
      assert :ok =
               FilterValidator.validate_all(UserResource, [], validate_relationships: false)
    end

    test "skips base_filter validation when validate_base is false" do
      assert :ok =
               FilterValidator.validate_all(StrictResource, [], validate_base: false)
    end

    test "validates aggregates when provided" do
      assert :ok =
               FilterValidator.validate_all(UserResource, [],
                 aggregates: [%{type: :count, name: :total}]
               )
    end

    test "validates calculations when provided" do
      assert :ok =
               FilterValidator.validate_all(UserResource, [],
                 calculations: [%{name: :calc, type: :string, expression: %{name: :name}}]
               )
    end

    test "skips relationship validation when validate_relationships is false" do
      assert :ok =
               FilterValidator.validate_all(UserResource, [], validate_relationships: false)
    end

    test "skips exists validation when validate_exists is false" do
      assert :ok =
               FilterValidator.validate_all(UserResource, [], validate_exists: false)
    end

    test "skips in validation when validate_in is false" do
      assert :ok =
               FilterValidator.validate_all(UserResource, [], validate_in: false)
    end

    test "raises if any validator fails" do
      assert_raise AshScylla.Error, fn ->
        FilterValidator.validate_all(UserResource, [
          %{operator: :eq, left: %{name: :age}, right: %{value: 30}}
        ])
      end
    end
  end
end
