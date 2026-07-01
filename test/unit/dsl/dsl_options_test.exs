defmodule AshScylla.DslPaginationConsistencyTest do
  @moduledoc """
  Tests for the pagination and per_action_consistency DSL options.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Dsl

  # ---------------------------------------------------------------------------
  # Test resources with new DSL options
  # ---------------------------------------------------------------------------

  defmodule ResourceWithTokenPagination do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      table("users")
      pagination(:token)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read])
    end
  end

  defmodule ResourceWithPerActionConsistency do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      table("users")
      consistency(:quorum)
      per_action_consistency(read: :one, create: :quorum, update: :local_quorum)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read, :update])
    end
  end

  defmodule ResourceWithBothNewOptions do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      table("users")
      pagination(:token)
      per_action_consistency(read: :one, create: :all)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read])
    end
  end

  defmodule ResourceWithDefaults do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      table("users")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read])
    end
  end

  # ---------------------------------------------------------------------------
  # pagination/1 tests
  # ---------------------------------------------------------------------------

  describe "Dsl.pagination/1" do
    test "returns :token for resource with pagination :token" do
      assert Dsl.pagination(ResourceWithTokenPagination) == :token
    end

    test "returns :token for resource with default pagination" do
      assert Dsl.pagination(ResourceWithDefaults) == :token
    end

    test "returns :token for resource without scylla config" do
      assert Dsl.pagination(String) == :token
    end

    test "returns :token for resource with both new options" do
      assert Dsl.pagination(ResourceWithBothNewOptions) == :token
    end
  end

  # ---------------------------------------------------------------------------
  # per_action_consistency/1 tests
  # ---------------------------------------------------------------------------

  describe "Dsl.per_action_consistency/1" do
    test "returns the per-action consistency map" do
      result = Dsl.per_action_consistency(ResourceWithPerActionConsistency)
      assert is_map(result)
      assert result[:read] == :one
      assert result[:create] == :quorum
      assert result[:update] == :local_quorum
    end

    test "returns empty map for resource without per_action_consistency" do
      assert Dsl.per_action_consistency(ResourceWithDefaults) == %{}
    end

    test "returns empty map for resource without ash_scylla config" do
      assert Dsl.per_action_consistency(String) == %{}
    end

    test "returns correct map for resource with both new options" do
      result = Dsl.per_action_consistency(ResourceWithBothNewOptions)
      assert result[:read] == :one
      assert result[:create] == :all
    end

    test "returns a map with atom keys" do
      result = Dsl.per_action_consistency(ResourceWithPerActionConsistency)
      assert Map.has_key?(result, :read)
      assert Map.has_key?(result, :create)
      assert Map.has_key?(result, :update)
    end
  end

  # ---------------------------------------------------------------------------
  # __ash_scylla__(:pagination) and __ash_scylla__(:per_action_consistency)
  # ---------------------------------------------------------------------------

  describe "__ash_scylla__ callbacks for new options" do
    test "ResourceWithTokenPagination returns :token from callback" do
      assert ResourceWithTokenPagination.__ash_scylla__(:pagination) == :token
    end

    test "ResourceWithDefaults returns :token from callback" do
      assert ResourceWithDefaults.__ash_scylla__(:pagination) == :token
    end

    test "ResourceWithPerActionConsistency returns map from callback" do
      result = ResourceWithPerActionConsistency.__ash_scylla__(:per_action_consistency)
      assert is_map(result)
      assert map_size(result) == 3
    end

    test "ResourceWithDefaults returns empty map from callback" do
      assert ResourceWithDefaults.__ash_scylla__(:per_action_consistency) == %{}
    end
  end
end
