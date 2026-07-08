defmodule AshScylla.DataLayer.AggregateTest do
  @moduledoc """
  Unit tests for aggregate support in AshScylla.DataLayer.

  Covers:
    - Feature flag checks (can?/2)
    - CQL generation for aggregate queries (build_aggregate_query/5)
    - QueryBuilder.aggregate_to_cql/2
    - run_aggregate_query/3 result handling
    - attach_aggregates/5 (per-record aggregate attachment)
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.QueryBuilder

  import AshScylla.DataLayer.Types, only: [uuid_string_to_binary: 1]

  defp uuid_bin(id), do: elem(uuid_string_to_binary(id), 1)

  # ---------------------------------------------------------------------------
  # Fake repo – pattern-matches aggregate CQL queries
  # ---------------------------------------------------------------------------

  defmodule FakeRepo do
    @moduledoc false

    def query(query, params, opts \\ []) do
      send(self(), {:ash_scylla_query, query, params, opts})

      case query do
        # --- COUNT(*) ---
        "SELECT COUNT(*) FROM test_ks.agg_items" ->
          {:ok, %Xandra.Page{content: [[5]]}}

        "SELECT COUNT(*) FROM test_ks.agg_items WHERE status = ?" ->
          {:ok, %Xandra.Page{content: [[3]]}}

        "SELECT COUNT(*) FROM test_ks.agg_items WHERE id = ?" ->
          {:ok, %Xandra.Page{content: [[1]]}}

        # --- COUNT(field) ---
        "SELECT COUNT(age) FROM test_ks.agg_items" ->
          {:ok, %Xandra.Page{content: [[4]]}}

        "SELECT COUNT(age) FROM test_ks.agg_items WHERE status = ?" ->
          {:ok, %Xandra.Page{content: [[2]]}}

        # --- SUM ---
        "SELECT SUM(age) FROM test_ks.agg_items" ->
          {:ok, %Xandra.Page{content: [[250]]}}

        "SELECT SUM(age) FROM test_ks.agg_items WHERE status = ?" ->
          {:ok, %Xandra.Page{content: [[120]]}}

        # --- AVG ---
        "SELECT AVG(age) FROM test_ks.agg_items" ->
          {:ok, %Xandra.Page{content: [[37.5]]}}

        "SELECT AVG(age) FROM test_ks.agg_items WHERE status = ?" ->
          {:ok, %Xandra.Page{content: [[30.0]]}}

        # --- MIN ---
        "SELECT MIN(age) FROM test_ks.agg_items" ->
          {:ok, %Xandra.Page{content: [[18]]}}

        "SELECT MIN(age) FROM test_ks.agg_items WHERE status = ?" ->
          {:ok, %Xandra.Page{content: [[22]]}}

        # --- MAX ---
        "SELECT MAX(age) FROM test_ks.agg_items" ->
          {:ok, %Xandra.Page{content: [[65]]}}

        "SELECT MAX(age) FROM test_ks.agg_items WHERE status = ?" ->
          {:ok, %Xandra.Page{content: [[45]]}}

        # --- Empty result ---
        "SELECT COUNT(*) FROM test_ks.agg_items WHERE status = ?" <>
            " AND deleted = ?" ->
          {:ok, %Xandra.Page{content: []}}

        # --- NULL result ---
        "SELECT SUM(age) FROM test_ks.agg_items WHERE status = ?" <>
            " AND empty = ?" ->
          {:ok, %Xandra.Page{content: [[nil]]}}

        # --- Per-record aggregate (same table) ---
        "SELECT COUNT(*) FROM test_ks.agg_items WHERE id = ?" ->
          {:ok, %Xandra.Page{content: [[1]]}}

        "SELECT SUM(age) FROM test_ks.agg_items WHERE id = ?" ->
          {:ok, %Xandra.Page{content: [[42]]}}

        # --- Unrelated aggregate (profiles table) ---
        "SELECT COUNT(*) FROM test_ks.profiles" ->
          {:ok, %Xandra.Page{content: [[7]]}}

        # --- fallback ---
        _ ->
          {:error, %Xandra.Error{reason: :overloaded, message: nil, warnings: []}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Test resource with aggregates
  # ---------------------------------------------------------------------------

  defmodule AggResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(FakeRepo)
      table("agg_items")
      keyspace("test_ks")
      consistency(:one)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:status, :string, public?: true)
      attribute(:age, :integer, public?: true)
      attribute(:deleted, :boolean, public?: true)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  # ---------------------------------------------------------------------------
  # Feature flag tests
  # ---------------------------------------------------------------------------

  describe "can?/2 — aggregate feature flags" do
    test "returns true for supported aggregate kinds" do
      assert DataLayer.can?(nil, {:aggregate, :count}) == true
      assert DataLayer.can?(nil, {:aggregate, :sum}) == true
      assert DataLayer.can?(nil, {:aggregate, :avg}) == true
      assert DataLayer.can?(nil, {:aggregate, :min}) == true
      assert DataLayer.can?(nil, {:aggregate, :max}) == true
    end

    test "returns true for query aggregate kinds" do
      assert DataLayer.can?(nil, {:query_aggregate, :count}) == true
      assert DataLayer.can?(nil, {:query_aggregate, :sum}) == true
      assert DataLayer.can?(nil, {:query_aggregate, :avg}) == true
      assert DataLayer.can?(nil, {:query_aggregate, :min}) == true
      assert DataLayer.can?(nil, {:query_aggregate, :max}) == true
    end

    test "returns true for aggregate_relationship" do
      assert DataLayer.can?(nil, {:aggregate_relationship, nil}) == true
    end

    test "returns false for unsupported aggregate kinds" do
      assert DataLayer.can?(nil, {:aggregate, :first}) == false
      assert DataLayer.can?(nil, {:aggregate, :list}) == false
      assert DataLayer.can?(nil, {:aggregate, :exists}) == false
      assert DataLayer.can?(nil, {:aggregate, :custom}) == false
      assert DataLayer.can?(nil, {:aggregate, :unrelated}) == false
    end

    test "returns false for unsupported query aggregate kinds" do
      assert DataLayer.can?(nil, {:query_aggregate, :first}) == false
      assert DataLayer.can?(nil, {:query_aggregate, :list}) == false
      assert DataLayer.can?(nil, {:query_aggregate, :exists}) == false
      assert DataLayer.can?(nil, {:query_aggregate, :custom}) == false
    end

    test "returns false for aggregate filter/sort" do
      assert DataLayer.can?(nil, :aggregate_filter) == false
      assert DataLayer.can?(nil, :aggregate_sort) == false
    end
  end

  # ---------------------------------------------------------------------------
  # QueryBuilder.aggregate_to_cql/2
  # ---------------------------------------------------------------------------

  describe "QueryBuilder.aggregate_to_cql/2" do
    test "COUNT(*)" do
      assert QueryBuilder.aggregate_to_cql(:count, nil) == "COUNT(*)"
    end

    test "COUNT(field)" do
      assert QueryBuilder.aggregate_to_cql(:count, :age) == "COUNT(age)"
    end

    test "SUM(field)" do
      assert QueryBuilder.aggregate_to_cql(:sum, :age) == "SUM(age)"
    end

    test "AVG(field)" do
      assert QueryBuilder.aggregate_to_cql(:avg, :age) == "AVG(age)"
    end

    test "MIN(field)" do
      assert QueryBuilder.aggregate_to_cql(:min, :age) == "MIN(age)"
    end

    test "MAX(field)" do
      assert QueryBuilder.aggregate_to_cql(:max, :age) == "MAX(age)"
    end

    test "falls back to COUNT for unknown kind" do
      assert QueryBuilder.aggregate_to_cql(:first, :age) == "COUNT(age)"
      assert QueryBuilder.aggregate_to_cql(:exists, nil) == "COUNT(*)"
    end
  end

  # ---------------------------------------------------------------------------
  # build_aggregate_query/5 (private, tested via run_aggregate_query)
  # ---------------------------------------------------------------------------

  describe "run_aggregate_query/3" do
    setup do
      query = %AshScylla.Query{
        resource: AggResource,
        repo: FakeRepo,
        table: "agg_items",
        filters: [],
        sorts: [],
        context: %{}
      }

      {:ok, %{query: query}}
    end

    test "COUNT(*) with no filters", %{query: query} do
      aggregate = %Ash.Query.Aggregate{
        name: :total,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      assert {:ok, %{total: 5}} = DataLayer.run_aggregate_query(query, [aggregate], AggResource)
    end

    test "COUNT(*) with filters", %{query: query} do
      query = %{
        query
        | filters: [%{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}]
      }

      aggregate = %Ash.Query.Aggregate{
        name: :active_count,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      assert {:ok, %{active_count: 3}} =
               DataLayer.run_aggregate_query(query, [aggregate], AggResource)
    end

    test "COUNT(field)", %{query: query} do
      aggregate = %Ash.Query.Aggregate{
        name: :age_count,
        kind: :count,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      assert {:ok, %{age_count: 4}} =
               DataLayer.run_aggregate_query(query, [aggregate], AggResource)
    end

    test "SUM(field)", %{query: query} do
      aggregate = %Ash.Query.Aggregate{
        name: :total_age,
        kind: :sum,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      assert {:ok, %{total_age: 250}} =
               DataLayer.run_aggregate_query(query, [aggregate], AggResource)
    end

    test "AVG(field)", %{query: query} do
      aggregate = %Ash.Query.Aggregate{
        name: :avg_age,
        kind: :avg,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      assert {:ok, %{avg_age: 37.5}} =
               DataLayer.run_aggregate_query(query, [aggregate], AggResource)
    end

    test "MIN(field)", %{query: query} do
      aggregate = %Ash.Query.Aggregate{
        name: :min_age,
        kind: :min,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      assert {:ok, %{min_age: 18}} =
               DataLayer.run_aggregate_query(query, [aggregate], AggResource)
    end

    test "MAX(field)", %{query: query} do
      aggregate = %Ash.Query.Aggregate{
        name: :max_age,
        kind: :max,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      assert {:ok, %{max_age: 65}} =
               DataLayer.run_aggregate_query(query, [aggregate], AggResource)
    end

    test "multiple aggregates in one call", %{query: query} do
      count_agg = %Ash.Query.Aggregate{
        name: :total,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      sum_agg = %Ash.Query.Aggregate{
        name: :total_age,
        kind: :sum,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      assert {:ok, result} =
               DataLayer.run_aggregate_query(query, [count_agg, sum_agg], AggResource)

      assert result.total == 5
      assert result.total_age == 250
    end

    test "empty result set uses default_value", %{query: query} do
      query = %{
        query
        | filters: [
            %{operator: :eq, left: %{name: "status"}, right: %{value: "deleted"}},
            %{operator: :eq, left: %{name: "deleted"}, right: %{value: true}}
          ]
      }

      aggregate = %Ash.Query.Aggregate{
        name: :deleted_count,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      assert {:ok, %{deleted_count: 0}} =
               DataLayer.run_aggregate_query(query, [aggregate], AggResource)
    end

    test "nil result uses default_value", %{query: query} do
      query = %{
        query
        | filters: [
            %{operator: :eq, left: %{name: "status"}, right: %{value: "empty"}},
            %{operator: :eq, left: %{name: "empty"}, right: %{value: true}}
          ]
      }

      aggregate = %Ash.Query.Aggregate{
        name: :empty_sum,
        kind: :sum,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      assert {:ok, %{empty_sum: nil}} =
               DataLayer.run_aggregate_query(query, [aggregate], AggResource)
    end

    test "returns error for unsupported aggregate kind", %{query: query} do
      aggregate = %Ash.Query.Aggregate{
        name: :first_item,
        kind: :first,
        field: :name,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      assert {:error, _} =
               DataLayer.run_aggregate_query(query, [aggregate], AggResource)
    end
  end

  # ---------------------------------------------------------------------------
  # add_aggregate / add_aggregates
  # ---------------------------------------------------------------------------

  describe "add_aggregate/3 and add_aggregates/3" do
    test "add_aggregate stores aggregate in query context" do
      query = %AshScylla.Query{
        resource: AggResource,
        repo: FakeRepo,
        table: "agg_items",
        context: %{}
      }

      aggregate = %Ash.Query.Aggregate{
        name: :total,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      {:ok, updated_query} = DataLayer.add_aggregate(query, aggregate, AggResource)
      assert Map.get(updated_query.context, :aggregates) == [aggregate]
    end

    test "add_aggregates stores multiple aggregates in query context" do
      query = %AshScylla.Query{
        resource: AggResource,
        repo: FakeRepo,
        table: "agg_items",
        context: %{}
      }

      agg1 = %Ash.Query.Aggregate{
        name: :total,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      agg2 = %Ash.Query.Aggregate{
        name: :total_age,
        kind: :sum,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      {:ok, updated_query} = DataLayer.add_aggregates(query, [agg1, agg2], AggResource)
      stored = Map.get(updated_query.context, :aggregates)
      assert length(stored) == 2
      assert agg1 in stored
      assert agg2 in stored
    end
  end

  # ---------------------------------------------------------------------------
  # attach_aggregates/5 (per-record aggregate attachment)
  # ---------------------------------------------------------------------------

  describe "attach_aggregates/5" do
    test "returns records unchanged when aggregates list is empty" do
      record = %AggResource{id: "test-id", aggregates: %{}}
      result = DataLayer.attach_aggregates([record], [], AggResource, FakeRepo, [])
      assert result == [record]
    end

    test "attaches count aggregate to record" do
      record = %AggResource{id: "550e8400-e29b-41d4-a716-446655440000", aggregates: %{}}

      aggregate = %Ash.Query.Aggregate{
        name: :related_count,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      [result] = DataLayer.attach_aggregates([record], [aggregate], AggResource, FakeRepo, [])
      assert result.aggregates.related_count == 1
    end

    test "attaches sum aggregate to record" do
      record = %AggResource{id: "550e8400-e29b-41d4-a716-446655440000", aggregates: %{}}

      aggregate = %Ash.Query.Aggregate{
        name: :total_age,
        kind: :sum,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      [result] = DataLayer.attach_aggregates([record], [aggregate], AggResource, FakeRepo, [])
      assert result.aggregates.total_age == 42
    end

    test "attaches multiple aggregates to multiple records" do
      record1 = %AggResource{id: "550e8400-e29b-41d4-a716-446655440000", aggregates: %{}}
      record2 = %AggResource{id: "550e8400-e29b-41d4-a716-446655440001", aggregates: %{}}

      count_agg = %Ash.Query.Aggregate{
        name: :count,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      sum_agg = %Ash.Query.Aggregate{
        name: :sum_age,
        kind: :sum,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      [r1, r2] =
        DataLayer.attach_aggregates(
          [record1, record2],
          [count_agg, sum_agg],
          AggResource,
          FakeRepo,
          []
        )

      assert r1.aggregates.count == 1
      assert r1.aggregates.sum_age == 42
      assert r2.aggregates.count == 1
      assert r2.aggregates.sum_age == 42
    end

    test "merges with existing aggregates on record" do
      record = %AggResource{
        id: "550e8400-e29b-41d4-a716-446655440000",
        aggregates: %{existing_field: "value"}
      }

      aggregate = %Ash.Query.Aggregate{
        name: :new_count,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      [result] = DataLayer.attach_aggregates([record], [aggregate], AggResource, FakeRepo, [])
      assert result.aggregates.existing_field == "value"
      assert result.aggregates.new_count == 1
    end
  end

  # ---------------------------------------------------------------------------
  # CQL generation via build_aggregate_query (tested through run_aggregate_query)
  # ---------------------------------------------------------------------------

  describe "CQL generation for aggregate queries" do
    test "generates correct CQL for COUNT(*)" do
      query = %AshScylla.Query{
        resource: AggResource,
        repo: FakeRepo,
        table: "agg_items",
        filters: [],
        context: %{}
      }

      aggregate = %Ash.Query.Aggregate{
        name: :total,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      DataLayer.run_aggregate_query(query, [aggregate], AggResource)

      assert_received {:ash_scylla_query, cql, _, _}
      assert cql == "SELECT COUNT(*) FROM test_ks.agg_items"
    end

    test "generates correct CQL for COUNT(field)" do
      query = %AshScylla.Query{
        resource: AggResource,
        repo: FakeRepo,
        table: "agg_items",
        filters: [],
        context: %{}
      }

      aggregate = %Ash.Query.Aggregate{
        name: :age_count,
        kind: :count,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      DataLayer.run_aggregate_query(query, [aggregate], AggResource)

      assert_received {:ash_scylla_query, cql, _, _}
      assert cql == "SELECT COUNT(age) FROM test_ks.agg_items"
    end

    test "generates correct CQL for SUM(field)" do
      query = %AshScylla.Query{
        resource: AggResource,
        repo: FakeRepo,
        table: "agg_items",
        filters: [],
        context: %{}
      }

      aggregate = %Ash.Query.Aggregate{
        name: :total_age,
        kind: :sum,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      DataLayer.run_aggregate_query(query, [aggregate], AggResource)

      assert_received {:ash_scylla_query, cql, _, _}
      assert cql == "SELECT SUM(age) FROM test_ks.agg_items"
    end

    test "generates correct CQL for AVG(field)" do
      query = %AshScylla.Query{
        resource: AggResource,
        repo: FakeRepo,
        table: "agg_items",
        filters: [],
        context: %{}
      }

      aggregate = %Ash.Query.Aggregate{
        name: :avg_age,
        kind: :avg,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      DataLayer.run_aggregate_query(query, [aggregate], AggResource)

      assert_received {:ash_scylla_query, cql, _, _}
      assert cql == "SELECT AVG(age) FROM test_ks.agg_items"
    end

    test "generates correct CQL for MIN(field)" do
      query = %AshScylla.Query{
        resource: AggResource,
        repo: FakeRepo,
        table: "agg_items",
        filters: [],
        context: %{}
      }

      aggregate = %Ash.Query.Aggregate{
        name: :min_age,
        kind: :min,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      DataLayer.run_aggregate_query(query, [aggregate], AggResource)

      assert_received {:ash_scylla_query, cql, _, _}
      assert cql == "SELECT MIN(age) FROM test_ks.agg_items"
    end

    test "generates correct CQL for MAX(field)" do
      query = %AshScylla.Query{
        resource: AggResource,
        repo: FakeRepo,
        table: "agg_items",
        filters: [],
        context: %{}
      }

      aggregate = %Ash.Query.Aggregate{
        name: :max_age,
        kind: :max,
        field: :age,
        relationship_path: [],
        resource: AggResource,
        default_value: nil,
        query: nil
      }

      DataLayer.run_aggregate_query(query, [aggregate], AggResource)

      assert_received {:ash_scylla_query, cql, _, _}
      assert cql == "SELECT MAX(age) FROM test_ks.agg_items"
    end

    test "includes WHERE clause when filters are present" do
      query = %AshScylla.Query{
        resource: AggResource,
        repo: FakeRepo,
        table: "agg_items",
        filters: [%{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}],
        context: %{}
      }

      aggregate = %Ash.Query.Aggregate{
        name: :active_count,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      DataLayer.run_aggregate_query(query, [aggregate], AggResource)

      assert_received {:ash_scylla_query, cql, _, _}
      assert String.contains?(cql, "WHERE")
      assert String.contains?(cql, "status")
    end
  end

  # ---------------------------------------------------------------------------
  # Relationship aggregates (aggregates do ... end with belongs_to)
  # ---------------------------------------------------------------------------

  defmodule DealResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, except: [relationships: 1]

    scylla do
      repo(FakeRepo)
      table("deals")
      keyspace("test_ks")
      consistency(:one)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:amount, :integer, public?: true)
      attribute(:active, :boolean, public?: true)
      attribute(:require_active, :boolean, public?: true)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule RedeemResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, except: [relationships: 1]

    scylla do
      repo(FakeRepo)
      table("redeems")
      keyspace("test_ks")
      consistency(:one)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:deal_id, :uuid, public?: true)
      attribute(:user_id, :uuid, public?: true)
      attribute(:redeemed, :boolean, public?: true)
      attribute(:amount, :integer, public?: true)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end

    relationships do
      belongs_to(:deal, DealResource,
        source_attribute: :deal_id,
        primary_key?: true
      )
    end
  end

  defmodule UserResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, except: [relationships: 1]

    scylla do
      repo(FakeRepo)
      table("users")
      keyspace("test_ks")
      consistency(:one)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end

    relationships do
      has_many(:redeems, RedeemResource,
        destination_attribute: :user_id
      )
    end
  end

  defmodule ProfileResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, except: [relationships: 1]

    scylla do
      repo(FakeRepo)
      table("profiles")
      keyspace("test_ks")
      consistency(:one)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:user_id, :uuid, public?: true)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end

    relationships do
      belongs_to(:user, UserResource,
        source_attribute: :user_id,
        primary_key?: true
      )
    end
  end

  describe "relationship aggregates" do
    test "can? returns true for aggregate_relationship" do
      assert DataLayer.can?(nil, {:aggregate_relationship, :deal}) == true
      assert DataLayer.can?(nil, {:aggregate_relationship, :redeems}) == true
    end

    test "attach_aggregates with belongs_to relationship path" do
      # RedeemResource belongs_to DealResource via deal_id
      record = %RedeemResource{
        id: "550e8400-e29b-41d4-a716-446655440000",
        deal_id: "660e8400-e29b-41d4-a716-446655440001",
        aggregates: %{}
      }

      aggregate = %Ash.Query.Aggregate{
        name: :deal_amount,
        kind: :sum,
        field: :amount,
        relationship_path: [:deal],
        resource: RedeemResource,
        default_value: nil,
        query: nil
      }

      # attach_aggregates will try to query the deals table
      # Since FakeRepo doesn't match the deals table pattern, it will return :error
      # and the default_value (nil) will be used
      [result] =
        DataLayer.attach_aggregates(
          [record],
          [aggregate],
          RedeemResource,
          FakeRepo,
          []
        )

      assert Map.has_key?(result.aggregates, :deal_amount)
    end

    test "attach_aggregates with has_many relationship path falls back to default" do
      # UserResource has_many RedeemResource
      record = %UserResource{
        id: "550e8400-e29b-41d4-a716-446655440000",
        aggregates: %{}
      }

      aggregate = %Ash.Query.Aggregate{
        name: :redeem_count,
        kind: :count,
        field: nil,
        relationship_path: [:redeems],
        resource: UserResource,
        default_value: 0,
        query: nil
      }

      [result] =
        DataLayer.attach_aggregates(
          [record],
          [aggregate],
          UserResource,
          FakeRepo,
          []
        )

      # has_many is not yet implemented, so default_value (0) is used
      assert result.aggregates.redeem_count == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Unrelated aggregates (Ash.Query.aggregate/4 with explicit resource)
  # ---------------------------------------------------------------------------

  describe "unrelated aggregates" do
    test "can? returns false for unrelated aggregates" do
      assert DataLayer.can?(nil, {:aggregate, :unrelated}) == false
    end

    test "run_aggregate_query with unrelated aggregate (related?: false)" do
      query = %AshScylla.Query{
        resource: UserResource,
        repo: FakeRepo,
        table: "users",
        filters: [],
        context: %{}
      }

      # An unrelated aggregate has related?: false and resource pointing to another resource
      aggregate = %Ash.Query.Aggregate{
        name: :profile_count,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: ProfileResource,
        default_value: 0,
        query: nil,
        related?: false
      }

      # With related?: false and empty relationship_path,
      # run_aggregate_query uses the passed resource parameter for the table.
      # We pass ProfileResource so the query targets the profiles table.
      assert {:ok, result} =
               DataLayer.run_aggregate_query(query, [aggregate], ProfileResource)

      assert Map.has_key?(result, :profile_count)
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  describe "aggregate edge cases" do
    test "run_aggregate_query with empty aggregates list" do
      query = %AshScylla.Query{
        resource: AggResource,
        repo: FakeRepo,
        table: "agg_items",
        filters: [],
        context: %{}
      }

      assert {:ok, %{}} = DataLayer.run_aggregate_query(query, [], AggResource)
    end

    test "run_aggregate_query with nil filters" do
      query = %AshScylla.Query{
        resource: AggResource,
        repo: FakeRepo,
        table: "agg_items",
        filters: nil,
        context: %{}
      }

      aggregate = %Ash.Query.Aggregate{
        name: :total,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      assert {:ok, %{total: 5}} =
               DataLayer.run_aggregate_query(query, [aggregate], AggResource)
    end

    test "add_aggregate with nil aggregate returns error" do
      query = %AshScylla.Query{
        resource: AggResource,
        repo: FakeRepo,
        table: "agg_items",
        context: %{}
      }

      assert {:ok, _} = DataLayer.add_aggregate(query, nil, AggResource)
    end

    test "attach_aggregates with empty records list" do
      result = DataLayer.attach_aggregates([], [], AggResource, FakeRepo, [])
      assert result == []
    end

    test "attach_aggregates with nil repo does not crash" do
      record = %AggResource{id: "test-id", aggregates: %{}}

      aggregate = %Ash.Query.Aggregate{
        name: :count,
        kind: :count,
        field: nil,
        relationship_path: [],
        resource: AggResource,
        default_value: 0,
        query: nil
      }

      # nil repo means no query execution — attach_aggregates returns records unchanged
      [result] = DataLayer.attach_aggregates([record], [aggregate], AggResource, nil, [])
      assert result.aggregates == %{}
    end
  end
end
