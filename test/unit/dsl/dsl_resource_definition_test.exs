defmodule AshScylla.DslResourceTest do
  @moduledoc """
  Unit tests for defining Ash resources using the `scylla` DSL block,
  including domain registration, all DSL options, and the full
  DSL → DataLayer → QueryBuilder pipeline.

  Resources and domains are defined inline via `defmodule` to exercise
  the full compilation pipeline.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.Dsl
  alias AshScylla.Query

  # ══════════════════════════════════════════════════════════════════════════
  # Inline test domains
  # ══════════════════════════════════════════════════════════════════════════

  defmodule TestDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false
  end

  defmodule EmptyDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Inline test resources — minimal DSL
  # ══════════════════════════════════════════════════════════════════════════

  defmodule SimpleResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(AshScylla.TestRepo)
      table("simple_items")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:status, :string)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Inline test resource — full DSL configuration
  # ══════════════════════════════════════════════════════════════════════════

  defmodule FullConfigResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(AshScylla.TestRepo)
      table("full_items")
      keyspace("test_keyspace")
      consistency(:quorum)
      ttl(7200)
      lwt(true)
      pagination(:token)
      per_action_consistency(read: :one, create: :quorum, update: :local_quorum)
      secondary_index(:email)
      secondary_index(:status, name: "idx_full_status")
      secondary_index([:name, :category])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:email, :string)
      attribute(:status, :string)
      attribute(:category, :string)
      attribute(:age, :integer)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Inline test resource — materialized view DSL
  # ══════════════════════════════════════════════════════════════════════════

  defmodule ResourceWithMaterializedView do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(AshScylla.TestRepo)
      table("events")
      keyspace("test_ks")
      consistency(:local_quorum)
      ttl(1800)
      lwt(false)
      pagination(:offset)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:event_type, :string)
      attribute(:payload, :string)
      attribute(:created_at, :utc_datetime)
    end

    actions do
      defaults([:create, :read])
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Inline test resource — no DSL block (bare resource)
  # ══════════════════════════════════════════════════════════════════════════

  defmodule BareResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string)
    end

    actions do
      defaults([:read])
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Inline test resource — DSL with only repo (no table override)
  # ══════════════════════════════════════════════════════════════════════════

  defmodule RepoOnlyResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(AshScylla.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:data, :string)
    end

    actions do
      defaults([:read])
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 1. DSL compilation: __ash_scylla__ callbacks
  # ══════════════════════════════════════════════════════════════════════════

  describe "DSL compilation: __ash_scylla__ callbacks" do
    test "simple resource exposes repo and table" do
      assert SimpleResource.__ash_scylla__(:repo) == AshScylla.TestRepo
      assert SimpleResource.__ash_scylla__(:table) == "simple_items"
    end

    test "full config resource exposes all options" do
      assert FullConfigResource.__ash_scylla__(:repo) == AshScylla.TestRepo
      assert FullConfigResource.__ash_scylla__(:table) == "full_items"
      assert FullConfigResource.__ash_scylla__(:keyspace) == "test_keyspace"
      assert FullConfigResource.__ash_scylla__(:consistency) == :quorum
      assert FullConfigResource.__ash_scylla__(:ttl) == 7200
      assert FullConfigResource.__ash_scylla__(:lwt) == true
      assert FullConfigResource.__ash_scylla__(:pagination) == :token
    end

    test "full config resource exposes per_action_consistency" do
      pac = FullConfigResource.__ash_scylla__(:per_action_consistency)
      assert pac[:read] == :one
      assert pac[:create] == :quorum
      assert pac[:update] == :local_quorum
    end

    test "full config resource exposes secondary indexes" do
      indexes = FullConfigResource.__ash_scylla__(:secondary_indexes)
      assert length(indexes) == 3

      # Single column index
      email_idx = Enum.find(indexes, &(&1.columns == [:email]))
      assert email_idx != nil
      assert email_idx.name == nil

      # Named single column index
      status_idx = Enum.find(indexes, &(&1.columns == [:status]))
      assert status_idx != nil
      assert status_idx.name == "idx_full_status"

      # Multi-column index
      multi_idx = Enum.find(indexes, &(&1.columns == [:name, :category]))
      assert multi_idx != nil
    end

    test "resource with materialized view exposes all DSL options" do
      assert ResourceWithMaterializedView.__ash_scylla__(:repo) == AshScylla.TestRepo
      assert ResourceWithMaterializedView.__ash_scylla__(:table) == "events"
      assert ResourceWithMaterializedView.__ash_scylla__(:keyspace) == "test_ks"
      assert ResourceWithMaterializedView.__ash_scylla__(:consistency) == :local_quorum
      assert ResourceWithMaterializedView.__ash_scylla__(:ttl) == 1800
      assert ResourceWithMaterializedView.__ash_scylla__(:lwt) == false
      assert ResourceWithMaterializedView.__ash_scylla__(:pagination) == :offset
      assert ResourceWithMaterializedView.__ash_scylla__(:materialized_views) == []
    end

    test "bare resource without DSL returns nil for all Dsl getters" do
      assert Dsl.table(BareResource) == nil
      assert Dsl.repo(BareResource) == nil
      assert Dsl.keyspace(BareResource) == nil
      assert Dsl.consistency(BareResource) == nil
      assert Dsl.ttl(BareResource) == nil
      assert Dsl.lwt(BareResource) == false
      assert Dsl.pagination(BareResource) == :token
      assert Dsl.secondary_indexes(BareResource) == []
      assert Dsl.materialized_views(BareResource) == []
      assert Dsl.per_action_consistency(BareResource) == %{}
    end

    test "repo-only resource exposes repo but nil for table" do
      assert RepoOnlyResource.__ash_scylla__(:repo) == AshScylla.TestRepo
      assert RepoOnlyResource.__ash_scylla__(:table) == nil
    end

    test "unknown option returns nil" do
      assert SimpleResource.__ash_scylla__(:nonexistent) == nil
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 2. Dsl module public API
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl module public API" do
    test "table/1 returns configured table" do
      assert Dsl.table(SimpleResource) == "simple_items"
      assert Dsl.table(FullConfigResource) == "full_items"
    end

    test "table/1 returns nil for resource without DSL" do
      assert Dsl.table(BareResource) == nil
    end

    test "table/1 returns nil for non-resource module" do
      assert Dsl.table(String) == nil
    end

    test "repo/1 returns configured repo" do
      assert Dsl.repo(SimpleResource) == AshScylla.TestRepo
      assert Dsl.repo(FullConfigResource) == AshScylla.TestRepo
    end

    test "repo/1 returns nil for resource without DSL" do
      assert Dsl.repo(BareResource) == nil
    end

    test "keyspace/1 returns configured keyspace" do
      assert Dsl.keyspace(FullConfigResource) == "test_keyspace"
      assert Dsl.keyspace(ResourceWithMaterializedView) == "test_ks"
    end

    test "keyspace/1 returns nil when not configured" do
      assert Dsl.keyspace(SimpleResource) == nil
    end

    test "consistency/1 returns configured consistency" do
      assert Dsl.consistency(FullConfigResource) == :quorum
      assert Dsl.consistency(ResourceWithMaterializedView) == :local_quorum
    end

    test "consistency/1 returns nil when not configured" do
      assert Dsl.consistency(SimpleResource) == nil
    end

    test "ttl/1 returns configured ttl" do
      assert Dsl.ttl(FullConfigResource) == 7200
      assert Dsl.ttl(ResourceWithMaterializedView) == 1800
    end

    test "ttl/1 returns nil when not configured" do
      assert Dsl.ttl(SimpleResource) == nil
    end

    test "lwt/1 returns configured lwt flag" do
      assert Dsl.lwt(FullConfigResource) == true
      assert Dsl.lwt(ResourceWithMaterializedView) == false
    end

    test "lwt/1 returns false when not configured" do
      assert Dsl.lwt(SimpleResource) == false
    end

    test "pagination/1 returns configured pagination mode" do
      assert Dsl.pagination(FullConfigResource) == :token
      assert Dsl.pagination(ResourceWithMaterializedView) == :offset
    end

    test "pagination/1 returns :token for resource without DSL" do
      assert Dsl.pagination(BareResource) == :token
    end

    test "per_action_consistency/1 returns configured map" do
      pac = Dsl.per_action_consistency(FullConfigResource)
      assert pac[:read] == :one
      assert pac[:create] == :quorum
      assert pac[:update] == :local_quorum
    end

    test "per_action_consistency/1 returns empty map when not configured" do
      assert Dsl.per_action_consistency(SimpleResource) == %{}
    end

    test "secondary_indexes/1 returns configured indexes" do
      indexes = Dsl.secondary_indexes(FullConfigResource)
      assert length(indexes) == 3
    end

    test "secondary_indexes/1 returns empty list when not configured" do
      assert Dsl.secondary_indexes(SimpleResource) == []
    end

    test "has_secondary_index?/2 checks column presence" do
      assert Dsl.has_secondary_index?(FullConfigResource, :email) == true
      assert Dsl.has_secondary_index?(FullConfigResource, :status) == true
      assert Dsl.has_secondary_index?(FullConfigResource, :name) == true
      assert Dsl.has_secondary_index?(FullConfigResource, :nonexistent) == false
      assert Dsl.has_secondary_index?(SimpleResource, :email) == false
    end

    test "materialized_views/1 returns empty list when not configured" do
      assert Dsl.materialized_views(SimpleResource) == []
    end

    test "materialized_views/1 returns empty list for resource without views" do
      assert Dsl.materialized_views(ResourceWithMaterializedView) == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 3. DSL → DataLayer: source/1 resolves table from DSL
  # ══════════════════════════════════════════════════════════════════════════

  describe "DSL → DataLayer: source/1" do
    test "resolves table from DSL for simple resource" do
      assert DataLayer.source(SimpleResource) == "simple_items"
    end

    test "resolves table from DSL for full config resource" do
      assert DataLayer.source(FullConfigResource) == "full_items"
    end

    test "resolves table from DSL for resource with all options" do
      assert DataLayer.source(ResourceWithMaterializedView) == "events"
    end

    test "falls back to underscored module name for bare resource" do
      assert DataLayer.source(BareResource) == "bare_resource"
    end

    test "repo-only resource falls back to underscored module name" do
      assert DataLayer.source(RepoOnlyResource) == "repo_only_resource"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 4. DSL → DataLayer: resource_to_query/2 builds correct struct
  # ══════════════════════════════════════════════════════════════════════════

  describe "DSL → DataLayer: resource_to_query/2" do
    test "builds query struct for simple resource" do
      query = DataLayer.resource_to_query(SimpleResource, nil)
      assert %AshScylla.Query{} = query
      assert query.resource == SimpleResource
      assert query.repo == AshScylla.TestRepo
      assert query.table == "simple_items"
    end

    test "builds query struct for full config resource" do
      query = DataLayer.resource_to_query(FullConfigResource, nil)
      assert %AshScylla.Query{} = query
      assert query.resource == FullConfigResource
      assert query.repo == AshScylla.TestRepo
      assert query.table == "full_items"
    end

    test "builds query struct with domain argument" do
      query = DataLayer.resource_to_query(SimpleResource, TestDomain)
      assert query.resource == SimpleResource
      assert query.repo == AshScylla.TestRepo
    end

    test "initializes defaults for all query fields" do
      query = DataLayer.resource_to_query(FullConfigResource, nil)
      assert query.filters == []
      assert query.sorts == []
      assert query.limit == nil
      assert query.select == nil
      assert query.tenant == nil
      assert query.context == %{}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 5. DSL → DataLayer: can?/2 feature detection
  # ══════════════════════════════════════════════════════════════════════════

  describe "DSL → DataLayer: can?/2 feature detection" do
    test "returns true for supported features on DSL resources" do
      assert DataLayer.can?(SimpleResource, :create) == true
      assert DataLayer.can?(SimpleResource, :read) == true
      assert DataLayer.can?(SimpleResource, :update) == true
      assert DataLayer.can?(SimpleResource, :destroy) == true
      assert DataLayer.can?(SimpleResource, :filter) == true
      assert DataLayer.can?(SimpleResource, :limit) == true
      assert DataLayer.can?(SimpleResource, :select) == true
      assert DataLayer.can?(SimpleResource, :multitenancy) == true
      assert DataLayer.can?(SimpleResource, :bulk_create) == true
      assert DataLayer.can?(SimpleResource, :upsert) == true
      assert DataLayer.can?(SimpleResource, :keyset) == true
      assert DataLayer.can?(SimpleResource, :boolean_filter) == true
      assert DataLayer.can?(SimpleResource, :distinct) == true
      assert DataLayer.can?(SimpleResource, {:atomic, :update}) == true
      assert DataLayer.can?(SimpleResource, {:atomic, :upsert}) == true
      assert DataLayer.can?(SimpleResource, {:aggregate, :count}) == true
    end

    test "returns false for unsupported features" do
      assert DataLayer.can?(SimpleResource, :transact) == true
      assert DataLayer.can?(SimpleResource, :sort) == true
      assert DataLayer.can?(SimpleResource, :offset) == false
      assert DataLayer.can?(SimpleResource, :lateral_join) == false
      assert DataLayer.can?(SimpleResource, :lock) == false
      assert DataLayer.can?(SimpleResource, {:aggregate, :sum}) == false
      assert DataLayer.can?(SimpleResource, {:combine, :union}) == false
    end

    test "can? works with bare resource too" do
      assert DataLayer.can?(BareResource, :create) == true
      assert DataLayer.can?(BareResource, :read) == true
      assert DataLayer.can?(BareResource, :transact) == true
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 6. DSL → DataLayer: callback chaining on DSL resources
  # ══════════════════════════════════════════════════════════════════════════

  describe "DSL → DataLayer: callback chaining" do
    test "filter → sort → limit → select chain on DSL resource" do
      query = DataLayer.resource_to_query(FullConfigResource, nil)

      f = %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
      {:ok, q1} = DataLayer.filter(query, f, nil)
      {:ok, q2} = DataLayer.sort(q1, [{:name, :asc}], nil)
      {:ok, q3} = DataLayer.limit(q2, 10, nil)
      {:ok, q4} = DataLayer.select(q3, [:id, :name, :status], nil)

      {cql, params} = AshScylla.DataLayer.QueryBuilder.build_optimized_query(q4)

      assert cql =~ "SELECT id, name, status FROM full_items"
      assert cql =~ "WHERE"
      # ScyllaDB does not support ORDER BY with secondary index scans;
      # status is a secondary-indexed column, so ORDER BY is stripped
      refute cql =~ "ORDER BY"
      assert cql =~ "LIMIT ?"
      assert "active" in params
      assert {"int", 10} in params
    end

    test "set_tenant and set_context on DSL resource" do
      query = DataLayer.resource_to_query(SimpleResource, nil)

      {:ok, q1} = DataLayer.set_tenant(SimpleResource, query, "tenant_abc")
      {:ok, q2} = DataLayer.set_context(SimpleResource, q1, %{request_id: "req-123"})

      assert q2.tenant == "tenant_abc"
      assert q2.context == %{request_id: "req-123"}
    end

    test "transform_query is a no-op on DSL resource query" do
      query = DataLayer.resource_to_query(SimpleResource, nil)
      result = DataLayer.transform_query(query)
      assert result == query
      assert is_struct(result, Query)
    end

    test "lock is a no-op" do
      query = DataLayer.resource_to_query(FullConfigResource, nil)
      {:ok, result} = DataLayer.lock(query, :for_update, nil)
      assert result == query
    end

    test "combination_of returns error" do
      query = DataLayer.resource_to_query(SimpleResource, nil)
      result = DataLayer.combination_of(query, :union, nil)
      assert {:error, error} = result
      assert is_struct(error, AshScylla.Error.ScyllaError)
      assert error.message =~ "UNION"
    end

    test "calculate stores calculation in context" do
      query = DataLayer.resource_to_query(FullConfigResource, nil)
      calculation = %{name: :full_name, expr: fn r -> r end}
      {:ok, result} = DataLayer.calculate(query, calculation, nil)
      assert result.context.calculations == [calculation]
    end

    test "add_aggregate stores aggregate in context" do
      query = DataLayer.resource_to_query(FullConfigResource, nil)
      aggregate = %{kind: :count, name: :total}
      {:ok, result} = DataLayer.add_aggregate(query, aggregate, nil)
      assert result.context.aggregates == [aggregate]
    end

    test "distinct on non-PK columns returns error" do
      query = DataLayer.resource_to_query(FullConfigResource, nil)
      result = DataLayer.distinct(query, [:email], FullConfigResource)
      assert {:error, error} = result
      assert is_struct(error, AshScylla.Error.ScyllaError)
      assert error.message =~ "DISTINCT on non-partition-key"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 7. DSL: secondary_index parsing edge cases
  # ══════════════════════════════════════════════════════════════════════════

  describe "DSL: secondary_index parsing" do
    defmodule SingleColumnIndexResource do
      @moduledoc false

      use Ash.Resource,
        domain: nil,
        data_layer: AshScylla.DataLayer

      import AshScylla.DataLayer.Dsl

      scylla do
        table("indexed_items")
        secondary_index(:email)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:email, :string)
      end

      actions do
        defaults([:read])
      end
    end

    defmodule NamedIndexResource do
      @moduledoc false

      use Ash.Resource,
        domain: nil,
        data_layer: AshScylla.DataLayer

      import AshScylla.DataLayer.Dsl

      scylla do
        table("named_index_items")
        secondary_index(:status, name: "idx_custom_status")
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:status, :string)
      end

      actions do
        defaults([:read])
      end
    end

    defmodule MultiColumnIndexResource do
      @moduledoc false

      use Ash.Resource,
        domain: nil,
        data_layer: AshScylla.DataLayer

      import AshScylla.DataLayer.Dsl

      scylla do
        table("multi_col_items")
        secondary_index([:first_name, :last_name])
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:first_name, :string)
        attribute(:last_name, :string)
      end

      actions do
        defaults([:read])
      end
    end

    test "single column index" do
      indexes = Dsl.secondary_indexes(SingleColumnIndexResource)
      assert length(indexes) == 1
      assert hd(indexes).columns == [:email]
      assert hd(indexes).name == nil
    end

    test "named index" do
      indexes = Dsl.secondary_indexes(NamedIndexResource)
      assert length(indexes) == 1
      assert hd(indexes).columns == [:status]
      assert hd(indexes).name == "idx_custom_status"
    end

    test "multi-column index" do
      indexes = Dsl.secondary_indexes(MultiColumnIndexResource)
      assert length(indexes) == 1
      assert hd(indexes).columns == [:first_name, :last_name]
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 8. Filter on unindexed columns raises errors
  # ══════════════════════════════════════════════════════════════════════════

  describe "Filter on unindexed columns raises errors" do
    defmodule StrictNonIndexedResource do
      @moduledoc false

      use Ash.Resource,
        domain: nil,
        data_layer: AshScylla.DataLayer

      import AshScylla.DataLayer.Dsl

      scylla do
        repo(AshScylla.TestRepo)
        table("strict_non_indexed_items")
        secondary_index(:email)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:email, :string)
        attribute(:game_id, :uuid)
        attribute(:status, :string)
      end

      actions do
        defaults([:read])
      end
    end

    test "run_query raises when filter is on non-indexed column" do
      query = DataLayer.resource_to_query(StrictNonIndexedResource, nil)

      f = %{
        operator: :eq,
        left: %{name: :game_id},
        right: %{value: "b1abe5c6-cd3d-4e50-bd77-d7b9dba22fb3"}
      }

      {:ok, q} = DataLayer.filter(query, f, nil)

      assert_raise AshScylla.Error, ~r/requires a secondary index/, fn ->
        DataLayer.run_query(q, StrictNonIndexedResource)
      end
    end

    test "run_query succeeds when filter is on indexed column" do
      query = DataLayer.resource_to_query(StrictNonIndexedResource, nil)

      f = %{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}}
      {:ok, q} = DataLayer.filter(query, f, nil)

      # The filter is on an indexed column, so validation should pass.
      # The query will fail with :not_connected since there's no DB in tests,
      # but it should NOT fail with "requires a secondary index".
      case DataLayer.run_query(q, StrictNonIndexedResource) do
        {:ok, records} ->
          assert is_list(records)

        {:error, %AshScylla.Error.ScyllaError{reason: :not_connected}} ->
          # Expected: validation passed but no DB connection available in test env
          :ok

        {:error, other} ->
          flunk("Expected :not_connected error but got: #{inspect(other)}")
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 10. DSL: materialized_view validation
  # ══════════════════════════════════════════════════════════════════════════

  describe "DSL: materialized_view" do
    test "returns empty list for resource without materialized views" do
      assert Dsl.materialized_views(SimpleResource) == []
    end

    test "returns empty list for resource with DSL but no views" do
      assert Dsl.materialized_views(ResourceWithMaterializedView) == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 9. DSL: error handling for missing repo
  # ══════════════════════════════════════════════════════════════════════════

  describe "DSL: error handling for missing repo" do
    defmodule ResourceWithDslTableOnly do
      @moduledoc false

      use Ash.Resource,
        domain: nil,
        data_layer: AshScylla.DataLayer

      import AshScylla.DataLayer.Dsl

      scylla do
        table("no_repo_table")
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:name, :string)
      end

      actions do
        defaults([:read])
      end
    end

    test "raises actionable error when DSL has table but no repo" do
      assert_raise RuntimeError, ~r/No repo configured for/, fn ->
        DataLayer.resource_to_query(ResourceWithDslTableOnly, nil)
      end
    end

    test "error message includes DSL configuration instructions" do
      error =
        assert_raise RuntimeError, fn ->
          DataLayer.resource_to_query(ResourceWithDslTableOnly, nil)
        end

      assert error.message =~ "scylla"
      assert error.message =~ "repo"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 10. Domain registration
  # ══════════════════════════════════════════════════════════════════════════

  describe "Domain registration" do
    test "domain module is defined" do
      assert function_exported?(TestDomain, :__spark_dsl__, 0) or
               Code.ensure_loaded?(TestDomain)
    end

    test "empty domain module is defined" do
      assert Code.ensure_loaded?(EmptyDomain)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 11. DSL: data_layer_keyset_by_default?
  # ══════════════════════════════════════════════════════════════════════════

  describe "DSL: data_layer_keyset_by_default?" do
    test "returns true for all resources" do
      assert DataLayer.data_layer_keyset_by_default?() == true
    end
  end
end
