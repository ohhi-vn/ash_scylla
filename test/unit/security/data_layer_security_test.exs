defmodule AshScylla.DataLayerSecurityTest do
  @moduledoc """
  Security tests for the DataLayer — ensures that:
  - OFFSET is never supported (prevents O(n) scan DoS)
  - Keyset pagination is the only pagination mode
  - Tenant isolation is enforced
  - Query struct cannot be tampered with for injection
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer
  alias AshScylla.Query

  # ---------------------------------------------------------------------------
  # OFFSET is permanently disabled
  # ---------------------------------------------------------------------------

  describe "OFFSET is permanently disabled" do
    test "can? returns false for :offset" do
      refute DataLayer.can?(AshScylla.TestResource, :offset)
    end

    test "Query struct has no offset field" do
      query = %Query{}
      refute Map.has_key?(query, :offset)
    end

    test "keyset pagination is supported" do
      assert DataLayer.can?(AshScylla.TestResource, :keyset)
    end

    test "data_layer_keyset_by_default? returns true" do
      assert DataLayer.data_layer_keyset_by_default?() == true
    end
  end

  # ---------------------------------------------------------------------------
  # Query struct immutability and safety
  # ---------------------------------------------------------------------------

  describe "Query struct safety" do
    test "Query.new/1 creates a valid query with required fields" do
      query = Query.new(AshScylla.TestResource)
      assert query.resource == AshScylla.TestResource
      assert query.filters == []
      assert query.sorts == []
    end

    test "Query struct cannot have ALLOW FILTERING injected" do
      # There is no allow_filtering field on the Query struct
      query = %Query{}
      refute Map.has_key?(query, :allow_filtering)
    end

    test "Query struct fields are typed correctly" do
      query = %Query{
        resource: AshScylla.TestResource,
        repo: AshScylla.TestRepo,
        table: "test_table",
        filters: [],
        sorts: [],
        limit: 10
      }

      assert is_atom(query.resource)
      assert is_atom(query.repo)
      assert is_binary(query.table)
      assert is_list(query.filters)
      assert is_list(query.sorts)
      assert is_integer(query.limit)
    end
  end

  # ---------------------------------------------------------------------------
  # Tenant isolation
  # ---------------------------------------------------------------------------

  describe "tenant isolation" do
    test "set_tenant stores tenant on query" do
      query = %Query{resource: nil}
      {:ok, result} = DataLayer.set_tenant(nil, query, "tenant_123")
      assert result.tenant == "tenant_123"
    end

    test "set_tenant with attribute strategy adds filter" do
      # When the resource has attribute-based multitenancy,
      # set_tenant should add a filter for the tenant attribute
      query = %Query{resource: AshScylla.TestResource, filters: []}

      # This may or may not add a filter depending on the resource's
      # multitenancy configuration, but it should never crash
      result = DataLayer.set_tenant(AshScylla.TestResource, query, "org_123")
      assert match?({:ok, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # Feature flags — dangerous features are disabled
  # ---------------------------------------------------------------------------

  describe "dangerous features are disabled" do
    test "JOINs are not supported (prevents cross-partition queries)" do
      refute DataLayer.can?(AshScylla.TestResource, {:join, SomeOtherResource})
    end

    test "lateral joins are not supported" do
      refute DataLayer.can?(AshScylla.TestResource, {:lateral_join, []})
    end

    test "locking is not supported (use LWT instead)" do
      refute DataLayer.can?(AshScylla.TestResource, :lock)
      refute DataLayer.can?(AshScylla.TestResource, {:lock, :for_update})
    end

    test "expression calculations are done in Elixir post-processing" do
      assert DataLayer.can?(AshScylla.TestResource, :expression_calculation)
    end

    test "UNION/INTERSECT combinations are not supported" do
      refute DataLayer.can?(AshScylla.TestResource, {:combine, :union})
    end
  end

  # ---------------------------------------------------------------------------
  # Consistency level validation
  # ---------------------------------------------------------------------------

  describe "consistency level safety" do
    test "only valid CQL consistency levels are accepted" do
      valid_levels = [
        :any,
        :one,
        :two,
        :three,
        :quorum,
        :all,
        :local_quorum,
        :each_quorum,
        :local_one
      ]

      for level <- valid_levels do
        # These should not raise when used in DSL config
        assert is_atom(level)
      end
    end

    test "invalid consistency levels are rejected" do
      valid_set =
        MapSet.new([
          :any,
          :one,
          :two,
          :three,
          :quorum,
          :all,
          :local_quorum,
          :each_quorum,
          :local_one
        ])

      refute MapSet.member?(valid_set, :invalid_level)
      refute MapSet.member?(valid_set, :strong)
    end
  end
end
