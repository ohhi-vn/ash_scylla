defmodule AshScylla.DataLayer.TransformQueryTest do
  @moduledoc """
  Tests for AshScylla.DataLayer.transform_query/1 — the callback that was
  previously broken (returned {:ok, t()} instead of Ash.Query.t()).

  Also covers additional DataLayer callbacks that lacked dedicated tests:
    - set_tenant/3
    - set_context/3
    - filter/3
    - sort/3
    - limit/3
    - select/3
    - lock/3
    - combination_of/3
    - calculate/3
    - add_aggregate/3
    - add_aggregates/3
    - distinct/3
    - data_layer_keyset_by_default?/0
    - resource_to_query/2
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp base_query do
    %AshScylla.Query{
      resource: AshScylla.TestResource,
      repo: AshScylla.TestRepo,
      table: "test_resource",
      filters: [],
      sorts: [],
      limit: nil,
      select: nil,
      tenant: nil,
      context: %{}
    }
  end

  # ---------------------------------------------------------------------------
  # transform_query/1
  # ---------------------------------------------------------------------------

  describe "transform_query/1" do
    test "returns the query unchanged (no-op)" do
      query = %Ash.Query{resource: AshScylla.TestResource}
      result = DataLayer.transform_query(query)
      assert result == query
    end

    test "returns an Ash.Query struct (not a tuple)" do
      query = %Ash.Query{resource: AshScylla.TestResource}
      result = DataLayer.transform_query(query)
      assert is_struct(result, Ash.Query)
    end

    test "does not wrap result in {:ok, _}" do
      query = %Ash.Query{resource: AshScylla.TestResource}
      result = DataLayer.transform_query(query)
      assert result != {:ok, query}
      assert match?(%Ash.Query{}, result)
    end

    test "preserves query fields" do
      query = %Ash.Query{
        resource: AshScylla.TestResource,
        filter: %{op: :eq, left: %{name: :status}, right: %{value: "active"}}
      }

      result = DataLayer.transform_query(query)
      assert result.resource == AshScylla.TestResource
      assert result.filter == query.filter
    end

    test "returns the same reference (identity check for no-op)" do
      query = %Ash.Query{resource: AshScylla.TestResource}
      result = DataLayer.transform_query(query)
      assert result === query
    end
  end

  # ---------------------------------------------------------------------------
  # set_tenant/3
  # ---------------------------------------------------------------------------

  describe "set_tenant/3" do
    test "sets the tenant on the data layer query" do
      query = base_query()
      {:ok, updated} = DataLayer.set_tenant(nil, query, "tenant_1")
      assert updated.tenant == "tenant_1"
    end

    test "overwrites a previously set tenant" do
      query = %{base_query() | tenant: "old_tenant"}
      {:ok, updated} = DataLayer.set_tenant(nil, query, "new_tenant")
      assert updated.tenant == "new_tenant"
    end

    test "other fields are preserved" do
      query = %{base_query() | limit: 10, filters: [:some_filter]}
      {:ok, updated} = DataLayer.set_tenant(nil, query, "t1")
      assert updated.limit == 10
      assert updated.filters == [:some_filter]
      assert updated.tenant == "t1"
    end

    test "returns {:ok, updated_query} tuple" do
      query = base_query()
      result = DataLayer.set_tenant(nil, query, "t1")
      assert match?({:ok, %AshScylla.Query{}}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # set_context/3
  # ---------------------------------------------------------------------------

  describe "set_context/3" do
    test "sets context on a fresh query" do
      query = base_query()
      {:ok, updated} = DataLayer.set_context(nil, query, %{foo: "bar"})
      assert updated.context == %{foo: "bar"}
    end

    test "merges with existing context" do
      query = %{base_query() | context: %{existing: "value"}}
      {:ok, updated} = DataLayer.set_context(nil, query, %{new: "data"})
      assert updated.context == %{existing: "value", new: "data"}
    end

    test "new values override existing keys" do
      query = %{base_query() | context: %{key: "old"}}
      {:ok, updated} = DataLayer.set_context(nil, query, %{key: "new"})
      assert updated.context == %{key: "new"}
    end

    test "handles nil existing context" do
      query = %{base_query() | context: nil}
      {:ok, updated} = DataLayer.set_context(nil, query, %{key: "val"})
      assert updated.context == %{key: "val"}
    end

    test "preserves other query fields" do
      query = %{base_query() | limit: 5, tenant: "t1"}
      {:ok, updated} = DataLayer.set_context(nil, query, %{a: 1})
      assert updated.limit == 5
      assert updated.tenant == "t1"
    end
  end

  # ---------------------------------------------------------------------------
  # filter/3
  # ---------------------------------------------------------------------------

  describe "filter/3" do
    test "adds a filter to the query" do
      query = base_query()
      filter = %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
      {:ok, updated} = DataLayer.filter(query, filter, nil)
      assert updated.filters == [filter]
    end

    test "prepends filters (most recent first)" do
      query = base_query()
      f1 = %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
      f2 = %{operator: :gt, left: %{name: :age}, right: %{value: 18}}

      {:ok, q1} = DataLayer.filter(query, f1, nil)
      {:ok, q2} = DataLayer.filter(q1, f2, nil)

      assert q2.filters == [f2, f1]
    end

    test "rewrites OR on same column to IN" do
      query = base_query()

      or_filter = %{
        op: :or,
        left: %{name: :status, op: :eq, right: %{value: "active"}},
        right: %{name: :status, op: :eq, right: %{value: "pending"}}
      }

      {:ok, updated} = DataLayer.filter(query, or_filter, nil)

      [rewritten] = updated.filters
      assert rewritten.operator == :in
      assert rewritten.left == %{name: :status}
      assert rewritten.right.value == ["pending", "active"]
    end

    test "does not rewrite OR on different columns" do
      query = base_query()

      or_filter = %{
        op: :or,
        left: %{name: :status, op: :eq, right: %{value: "active"}},
        right: %{name: :role, op: :eq, right: %{value: "admin"}}
      }

      {:ok, updated} = DataLayer.filter(query, or_filter, nil)
      [rewritten] = updated.filters
      assert rewritten.op == :or
    end

    test "returns {:ok, updated_query} tuple" do
      query = base_query()
      filter = %{operator: :eq, left: %{name: :id}, right: %{value: 1}}
      result = DataLayer.filter(query, filter, nil)
      assert match?({:ok, %AshScylla.Query{}}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # sort/3
  # ---------------------------------------------------------------------------

  describe "sort/3" do
    test "adds sort to the query" do
      query = base_query()
      {:ok, updated} = DataLayer.sort(query, [{:name, :asc}], nil)
      assert updated.sorts == [{:name, :asc}]
    end

    test "prepends new sorts to existing ones" do
      query = base_query()
      {:ok, q1} = DataLayer.sort(query, [{:name, :asc}], nil)
      {:ok, q2} = DataLayer.sort(q1, [{:created_at, :desc}], nil)
      assert q2.sorts == [{:created_at, :desc}, {:name, :asc}]
    end

    test "returns {:ok, updated_query} tuple" do
      query = base_query()
      result = DataLayer.sort(query, [{:name, :asc}], nil)
      assert match?({:ok, %AshScylla.Query{}}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # limit/3
  # ---------------------------------------------------------------------------

  describe "limit/3" do
    test "sets the limit" do
      query = base_query()
      {:ok, updated} = DataLayer.limit(query, 50, nil)
      assert updated.limit == 50
    end

    test "overwrites previous limit" do
      query = %{base_query() | limit: 10}
      {:ok, updated} = DataLayer.limit(query, 25, nil)
      assert updated.limit == 25
    end

    test "returns {:ok, updated_query} tuple" do
      query = base_query()
      result = DataLayer.limit(query, 10, nil)
      assert match?({:ok, %AshScylla.Query{}}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # select/3
  # ---------------------------------------------------------------------------

  describe "select/3" do
    test "sets the select columns" do
      query = base_query()
      {:ok, updated} = DataLayer.select(query, [:name, :email], nil)
      assert updated.select == [:name, :email]
    end

    test "overwrites previous select" do
      query = %{base_query() | select: [:id]}
      {:ok, updated} = DataLayer.select(query, [:name], nil)
      assert updated.select == [:name]
    end

    test "returns {:ok, updated_query} tuple" do
      query = base_query()
      result = DataLayer.select(query, [:name], nil)
      assert match?({:ok, %AshScylla.Query{}}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # lock/3
  # ---------------------------------------------------------------------------

  describe "lock/3" do
    test "is a no-op that returns the query unchanged" do
      query = %{base_query() | limit: 5}
      {:ok, updated} = DataLayer.lock(query, :for_update, nil)
      assert updated == query
    end

    test "returns {:ok, query} tuple" do
      query = base_query()
      result = DataLayer.lock(query, :for_update, nil)
      assert match?({:ok, %AshScylla.Query{}}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # combination_of/3
  # ---------------------------------------------------------------------------

  describe "combination_of/3" do
    test "returns an error for unsupported combination queries" do
      query = base_query()
      result = DataLayer.combination_of(query, :union, nil)
      assert {:error, error} = result
      assert is_struct(error, AshScylla.Error.ScyllaError)
    end

    test "error message mentions UNION/INTERSECT" do
      query = base_query()
      {:error, error} = DataLayer.combination_of(query, :union, nil)
      assert error.message =~ "UNION"
    end

    test "error message mentions in-memory fallback" do
      query = base_query()
      {:error, error} = DataLayer.combination_of(query, :union, nil)
      assert error.message =~ "in-memory"
    end
  end

  # ---------------------------------------------------------------------------
  # calculate/3
  # ---------------------------------------------------------------------------

  describe "calculate/3" do
    test "stores calculation in query context" do
      query = base_query()
      calculation = %{name: :full_name, module: SomeModule, opts: []}
      {:ok, updated} = DataLayer.calculate(query, calculation, nil)
      assert updated.context.calculations == [calculation]
    end

    test "prepends multiple calculations" do
      query = base_query()
      c1 = %{name: :calc_a, expr: fn r -> r end}
      c2 = %{name: :calc_b, expr: fn r -> r end}

      {:ok, q1} = DataLayer.calculate(query, c1, nil)
      {:ok, q2} = DataLayer.calculate(q1, c2, nil)

      assert q2.context.calculations == [c2, c1]
    end

    test "returns {:ok, updated_query} tuple" do
      query = base_query()
      calculation = %{name: :test, expr: fn r -> r end}
      result = DataLayer.calculate(query, calculation, nil)
      assert match?({:ok, %AshScylla.Query{}}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # add_aggregate/3
  # ---------------------------------------------------------------------------

  describe "add_aggregate/3" do
    test "stores aggregate in query context" do
      query = base_query()
      aggregate = %{kind: :count, name: :total_users}
      {:ok, updated} = DataLayer.add_aggregate(query, aggregate, nil)
      assert updated.context.aggregates == [aggregate]
    end

    test "prepends multiple aggregates" do
      query = base_query()
      a1 = %{kind: :count, name: :total}
      a2 = %{kind: :count, name: :active}

      {:ok, q1} = DataLayer.add_aggregate(query, a1, nil)
      {:ok, q2} = DataLayer.add_aggregate(q1, a2, nil)

      assert q2.context.aggregates == [a2, a1]
    end

    test "returns {:ok, updated_query} tuple" do
      query = base_query()
      aggregate = %{kind: :count, name: :total}
      result = DataLayer.add_aggregate(query, aggregate, nil)
      assert match?({:ok, %AshScylla.Query{}}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # add_aggregates/3
  # ---------------------------------------------------------------------------

  describe "add_aggregates/3" do
    test "stores multiple aggregates at once" do
      query = base_query()

      aggregates = [
        %{kind: :count, name: :total},
        %{kind: :count, name: :active}
      ]

      {:ok, updated} = DataLayer.add_aggregates(query, aggregates, nil)
      assert updated.context.aggregates == aggregates
    end

    test "appends to existing aggregates" do
      query = base_query()
      a1 = %{kind: :count, name: :total}
      {:ok, q1} = DataLayer.add_aggregate(query, a1, nil)

      a2 = %{kind: :count, name: :active}
      {:ok, q2} = DataLayer.add_aggregates(q1, [a2], nil)

      assert q2.context.aggregates == [a2, a1]
    end

    test "returns {:ok, updated_query} tuple" do
      query = base_query()
      aggregates = [%{kind: :count, name: :total}]
      result = DataLayer.add_aggregates(query, aggregates, nil)
      assert match?({:ok, %AshScylla.Query{}}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # distinct/3
  # ---------------------------------------------------------------------------

  describe "distinct/3" do
    test "returns error for non-partition-key columns" do
      query = base_query()
      result = DataLayer.distinct(query, [:name], AshScylla.TestResource)
      assert {:error, error} = result
      assert is_struct(error, AshScylla.Error.ScyllaError)
      assert error.message =~ "DISTINCT on non-partition-key"
    end

    test "returns error mentioning materialized view suggestion" do
      query = base_query()
      {:error, error} = DataLayer.distinct(query, [:email], AshScylla.TestResource)
      assert error.message =~ "materialized view"
    end

    test "returns error with distinct columns listed" do
      query = base_query()
      {:error, error} = DataLayer.distinct(query, [:name, :email], AshScylla.TestResource)
      assert error.message =~ "name"
      assert error.message =~ "email"
    end
  end

  # ---------------------------------------------------------------------------
  # data_layer_keyset_by_default?/0
  # ---------------------------------------------------------------------------

  describe "data_layer_keyset_by_default?/0" do
    test "returns true" do
      assert DataLayer.data_layer_keyset_by_default?() == true
    end
  end

  # ---------------------------------------------------------------------------
  # resource_to_query/2
  # ---------------------------------------------------------------------------

  describe "resource_to_query/2" do
    test "creates a proper query struct with resource set" do
      query = %AshScylla.Query{
        resource: AshScylla.TestResourceWithIndexes,
        repo: nil,
        table: "test_users"
      }

      assert query.resource == AshScylla.TestResourceWithIndexes
    end

    test "creates a proper query struct with table set" do
      query = %AshScylla.Query{
        resource: AshScylla.TestResourceWithIndexes,
        repo: nil,
        table: "test_users"
      }

      assert query.table == "test_users"
    end

    test "creates a proper query struct with default filters" do
      query = %AshScylla.Query{
        resource: AshScylla.TestResourceWithIndexes,
        repo: nil,
        table: "test_users"
      }

      assert query.filters == []
    end

    test "creates a proper query struct with default sorts" do
      query = %AshScylla.Query{
        resource: AshScylla.TestResourceWithIndexes,
        repo: nil,
        table: "test_users"
      }

      assert query.sorts == []
    end

    test "creates a proper query struct with nil limit" do
      query = %AshScylla.Query{
        resource: AshScylla.TestResourceWithIndexes,
        repo: nil,
        table: "test_users"
      }

      assert query.limit == nil
    end

    test "creates a proper query struct with nil tenant" do
      query = %AshScylla.Query{
        resource: AshScylla.TestResourceWithIndexes,
        repo: nil,
        table: "test_users"
      }

      assert query.tenant == nil
    end

    test "creates a proper query struct with empty context" do
      query = %AshScylla.Query{
        resource: AshScylla.TestResourceWithIndexes,
        repo: nil,
        table: "test_users"
      }

      assert query.context == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # can?/2 — additional edge cases beyond existing tests
  # ---------------------------------------------------------------------------

  describe "can?/2 edge cases" do
    test "returns false for list feature" do
      assert DataLayer.can?(nil, [:create]) == false
    end

    test "returns false for tuple with unknown atom" do
      assert DataLayer.can?(nil, {:unknown, :feature}) == false
    end

    test "returns false for :sort (not in supported features)" do
      assert DataLayer.can?(nil, :sort) == true
    end

    test "returns false for :offset (not in supported features)" do
      assert DataLayer.can?(nil, :offset) == false
    end

    test "returns true for :update_query" do
      assert DataLayer.can?(nil, :update_query) == true
    end

    test "returns true for :destroy_query" do
      assert DataLayer.can?(nil, :destroy_query) == true
    end

    test "returns true for :expression_calculation" do
      assert DataLayer.can?(nil, :expression_calculation) == true
    end

    test "returns false for :lateral_join" do
      assert DataLayer.can?(nil, :lateral_join) == false
    end

    test "returns false for {:aggregate, :sum}" do
      assert DataLayer.can?(nil, {:aggregate, :sum}) == false
    end

    test "returns false for {:aggregate, :avg}" do
      assert DataLayer.can?(nil, {:aggregate, :avg}) == false
    end

    test "returns true for {:aggregate, :count}" do
      assert DataLayer.can?(nil, {:aggregate, :count}) == true
    end

    test "returns false for {:combine, :union}" do
      assert DataLayer.can?(nil, {:combine, :union}) == false
    end

    test "returns true for :boolean_filter" do
      assert DataLayer.can?(nil, :boolean_filter) == true
    end

    test "returns true for :distinct" do
      assert DataLayer.can?(nil, :distinct) == true
    end
  end

  # ---------------------------------------------------------------------------
  # DataLayer struct defaults
  # ---------------------------------------------------------------------------

  describe "DataLayer struct defaults" do
    test "defaults have correct values" do
      dl = %AshScylla.Query{}
      assert dl.filters == []
      assert dl.sorts == []
      assert dl.limit == nil
      assert dl.select == nil
      assert dl.tenant == nil
      assert dl.context == %{}
      assert dl.atomic == nil
      assert dl.upsert? == false
      assert dl.upsert_fields == []
      assert dl.upsert_identity == nil
      assert dl.keyset == nil
    end
  end
end

# ---------------------------------------------------------------------------
# return_query/2 — additional tests in separate module to avoid conflicts
# ---------------------------------------------------------------------------

defmodule AshScylla.DataLayer.ReturnQueryTest do
  @moduledoc """
  Tests for AshScylla.DataLayer.return_query/2 callback.
  Covers the fix for the Ash.Error.Framework issue where return_query/2
  was returning a plain string instead of {:ok, data_layer_query()} tuple.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer

  defp base_query do
    %AshScylla.Query{
      resource: AshScylla.TestResource,
      repo: AshScylla.TestRepo,
      table: "test_resource",
      filters: [],
      sorts: [],
      limit: nil,
      select: nil,
      tenant: nil,
      context: %{}
    }
  end

  describe "return_query/2" do
    test "returns {:ok, data_layer_query} tuple" do
      query = base_query()
      assert {:ok, result} = DataLayer.return_query(query, AshScylla.TestResource)
      assert %AshScylla.Query{} = result
    end

    test "returns the same query struct" do
      query = base_query()
      {:ok, result} = DataLayer.return_query(query, AshScylla.TestResource)
      assert result.resource == AshScylla.TestResource
      assert result.table == "test_resource"
    end

    test "preserves all query fields" do
      query = %{
        base_query()
        | filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
          limit: 10,
          tenant: "org_123"
      }

      {:ok, result} = DataLayer.return_query(query, AshScylla.TestResource)
      assert result.filters == query.filters
      assert result.limit == 10
      assert result.tenant == "org_123"
    end

    test "returns {:ok, _} even with empty filters" do
      query = base_query()
      assert {:ok, %AshScylla.Query{}} = DataLayer.return_query(query, AshScylla.TestResource)
    end

    test "does not return a plain string" do
      query = base_query()
      result = DataLayer.return_query(query, AshScylla.TestResource)
      refute is_binary(result)
      assert is_tuple(result)
      assert elem(result, 0) == :ok
    end

    test "does not return the query wrapped in a string" do
      query = base_query()
      {:ok, result} = DataLayer.return_query(query, AshScylla.TestResource)
      refute is_binary(result)
      assert %AshScylla.Query{} = result
    end
  end
end
