defmodule AshScylla.DataLayerTypeMappingTest do
  @moduledoc """
  Coverage for the pure mapping/translation surface of `AshScylla.DataLayer`:
  Ash→CQL type mapping, typed value wrapping, record decoding, query-callback
  shims (transactions, tenant, context, sort, distinct, lock), and table-name
  resolution.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer
  alias AshScylla.TestResource
  alias AshScylla.TestResourceCompositePK
  alias AshScylla.TestResourceNoKeyspace

  defmodule FakeRepoShim do
    @moduledoc false
    def query(_query, _params, _opts \\ []), do: {:error, :unused}
  end

  # ---------------------------------------------------------------------------
  # Inline resources used by the multitenancy / base-filter / type-map tests.
  # ---------------------------------------------------------------------------

  defmodule TypedResource do
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, only: [scylla: 1]

    scylla do
      repo(AshScylla.TestRepo)
      table("dl_typed")
      keyspace("type_mapping_ks")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:v7, :uuid_v7, public?: true)
      attribute(:status, :atom, public?: true)
      attribute(:name, :string, public?: true)
      attribute(:score, :float, public?: true)
      attribute(:tags, {:array, :string}, public?: true)
    end
  end

  defmodule ContextMultitenantResource do
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, only: [scylla: 1]

    scylla do
      repo(AshScylla.TestRepo)
      table("dl_mt_context")
      keyspace("type_mapping_ks")
    end

    multitenancy do
      strategy(:context)
    end

    attributes do
      uuid_primary_key(:id)
    end
  end

  defmodule AttributeMultitenantResource do
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, only: [scylla: 1]

    scylla do
      repo(AshScylla.TestRepo)
      table("dl_mt_attr")
      keyspace("type_mapping_ks")
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :string, public?: true, allow_nil?: false, primary_key?: true)
    end
  end

  defmodule AttributeMultitenantNoAttrResource do
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, only: [scylla: 1]

    scylla do
      repo(AshScylla.TestRepo)
      table("dl_mt_attr_none")
      keyspace("type_mapping_ks")
    end

    multitenancy do
      strategy(:attribute)
    end

    attributes do
      uuid_primary_key(:id)
    end
  end

  defmodule BaseFilteredResource do
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, only: [scylla: 1]

    scylla do
      repo(AshScylla.TestRepo)
      table("dl_base_filtered")
      keyspace("type_mapping_ks")
      base_filter([deleted: false])
      default_context(%{tenant: "acme"})
      lwt(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:deleted, :boolean, public?: true)
    end
  end

  describe "ash_type_to_cql/1" do
    test "module-based types" do
      assert DataLayer.ash_type_to_cql(Ash.Type.UUID) == "uuid"
      assert DataLayer.ash_type_to_cql(Ash.Type.Integer) == "bigint"
      assert DataLayer.ash_type_to_cql(Ash.Type.Float) == "double"
      assert DataLayer.ash_type_to_cql(Ash.Type.Boolean) == "boolean"
      assert DataLayer.ash_type_to_cql(Ash.Type.String) == "text"
      assert DataLayer.ash_type_to_cql(Ash.Type.DateTime) == "timestamp"
      assert DataLayer.ash_type_to_cql(Ash.Type.Date) == "date"
      assert DataLayer.ash_type_to_cql(Ash.Type.Time) == "time"
      assert DataLayer.ash_type_to_cql(Ash.Type.Decimal) == "decimal"
      assert DataLayer.ash_type_to_cql(Ash.Type.Atom) == "text"
      assert DataLayer.ash_type_to_cql(Ash.Type.CiString) == "text"
      assert DataLayer.ash_type_to_cql(Ash.Type.Binary) == "blob"
    end

    test "atom short names" do
      assert DataLayer.ash_type_to_cql(:uuid) == "uuid"
      assert DataLayer.ash_type_to_cql(:uuid_v7) == "uuid"
      assert DataLayer.ash_type_to_cql(:integer) == "bigint"
      assert DataLayer.ash_type_to_cql(:float) == "double"
      assert DataLayer.ash_type_to_cql(:double) == "double"
      assert DataLayer.ash_type_to_cql(:boolean) == "boolean"
      assert DataLayer.ash_type_to_cql(:string) == "text"
      assert DataLayer.ash_type_to_cql(:text) == "text"
      assert DataLayer.ash_type_to_cql(:utc_datetime) == "timestamp"
      assert DataLayer.ash_type_to_cql(:utc_datetime_usec) == "timestamp"
      assert DataLayer.ash_type_to_cql(:naive_datetime) == "timestamp"
      assert DataLayer.ash_type_to_cql(:naive_datetime_usec) == "timestamp"
      assert DataLayer.ash_type_to_cql(:timestamp) == "timestamp"
      assert DataLayer.ash_type_to_cql(:date) == "date"
      assert DataLayer.ash_type_to_cql(:time) == "time"
      assert DataLayer.ash_type_to_cql(:time_usec) == "time"
      assert DataLayer.ash_type_to_cql(:decimal) == "decimal"
      assert DataLayer.ash_type_to_cql(:binary) == "blob"
      assert DataLayer.ash_type_to_cql(:duration) == "duration"
      assert DataLayer.ash_type_to_cql(:ci_string) == "text"
      assert DataLayer.ash_type_to_cql(:atom) == "text"
    end

    test "collection and parameterized types" do
      assert DataLayer.ash_type_to_cql(:list) == "list<text>"
      assert DataLayer.ash_type_to_cql(:map) == "map<text, text>"
      assert DataLayer.ash_type_to_cql(:set) == "set<text>"
      assert DataLayer.ash_type_to_cql({:array, :uuid}) == "list<uuid>"
      assert DataLayer.ash_type_to_cql({:set, :integer}) == "set<bigint>"
      assert DataLayer.ash_type_to_cql({:map, :string, :uuid}) == "map<text, uuid>"
      assert DataLayer.ash_type_to_cql({:tuple, [:uuid, :integer]}) == "tuple<uuid, bigint>"
    end

    test "unknown types fall back to text" do
      assert DataLayer.ash_type_to_cql(:definitely_not_a_type) == "text"
      assert DataLayer.ash_type_to_cql({:weird, :shape}) == "text"
    end
  end

  describe "wrap_typed/3" do
    test "already-typed tuples pass through" do
      assert DataLayer.wrap_typed({"int", 3}, :x, %{}) == {"int", 3}
    end

    test "nil wraps as text nil" do
      assert DataLayer.wrap_typed(nil, :x, %{}) == {"text", nil}
    end

    test "booleans always wrap as boolean" do
      assert DataLayer.wrap_typed(true, :x, %{x: "text"}) == {"boolean", true}
      assert DataLayer.wrap_typed(false, :x, %{}) == {"boolean", false}
    end

    test "floats use the declared float/double type when available" do
      assert DataLayer.wrap_typed(1.5, :f, %{f: "float"}) == {"float", 1.5}
      assert DataLayer.wrap_typed(1.5, :f, %{f: "double"}) == {"double", 1.5}
      assert DataLayer.wrap_typed(1.5, :f, %{}) == {"double", 1.5}
      assert DataLayer.wrap_typed(1.5, :f, %{f: "text"}) == {"double", 1.5}
      assert DataLayer.wrap_typed(1.5, "f", %{"f" => "float"}) == {"float", 1.5}
    end

    test "integers use declared integer-family type or default to bigint" do
      assert DataLayer.wrap_typed(5, :i, %{i: "int"}) == {"int", 5}
      assert DataLayer.wrap_typed(5, :i, %{i: "smallint"}) == {"smallint", 5}
      assert DataLayer.wrap_typed(5, :i, %{i: "tinyint"}) == {"tinyint", 5}
      assert DataLayer.wrap_typed(5, :i, %{i: "counter"}) == {"counter", 5}
      assert DataLayer.wrap_typed(5, :i, %{i: "varint"}) == {"varint", 5}
      assert DataLayer.wrap_typed(5, :i, %{i: "bigint"}) == {"bigint", 5}
      assert DataLayer.wrap_typed(5, :i, %{}) == {"bigint", 5}
      assert DataLayer.wrap_typed(5, :i, %{i: "text"}) == {"bigint", 5}
    end

    test "atoms convert to strings with declared or default text type" do
      assert DataLayer.wrap_typed(:ok, :s, %{s: "text"}) == {"text", "ok"}
      assert DataLayer.wrap_typed(:ok, :s, %{}) == {"text", "ok"}
      assert DataLayer.wrap_typed(:ok, "s", %{"s" => "inet"}) == {"inet", "ok"}
    end

    test "binaries use declared or default text type" do
      assert DataLayer.wrap_typed("hi", :b, %{b: "uuid"}) == {"uuid", "hi"}
      assert DataLayer.wrap_typed("hi", :b, %{}) == {"text", "hi"}
      assert DataLayer.wrap_typed("hi", "b", %{"b" => "blob"}) == {"blob", "hi"}
    end

    test "lists use declared list type or default list<text>" do
      assert DataLayer.wrap_typed([1, 2], :l, %{l: "list<int>"}) == {"list<int>", [1, 2]}
      assert DataLayer.wrap_typed([1, 2], :l, %{}) == {"list<text>", [1, 2]}
      assert DataLayer.wrap_typed([1, 2], :l, %{l: "map<text,text>"}) == {"list<text>", [1, 2]}
      assert DataLayer.wrap_typed([1, 2], "l", %{"l" => "list<uuid>"}) == {"list<uuid>", [1, 2]}
    end

    test "maps use declared map type or default map<text, text>" do
      assert DataLayer.wrap_typed(%{a: 1}, :m, %{m: "map<text,int>"}) == {"map<text,int>", %{a: 1}}
      assert DataLayer.wrap_typed(%{a: 1}, :m, %{}) == {"map<text, text>", %{a: 1}}
      assert DataLayer.wrap_typed(%{a: 1}, :m, %{m: "list<int>"}) ==
               {"map<text, text>", %{a: 1}}
    end

    test "structs pass through unchanged" do
      now = DateTime.utc_now()
      assert DataLayer.wrap_typed(now, :d, %{}) == now
      assert DataLayer.wrap_typed(Date.utc_today(), :d, %{}) == Date.utc_today()
      assert DataLayer.wrap_typed(~T[12:00:00], :t, %{}) == ~T[12:00:00]
      assert DataLayer.wrap_typed(Decimal.new(1), :dec, %{}) == Decimal.new(1)
      assert DataLayer.wrap_typed(MapSet.new([1]), :ms, %{}) == MapSet.new([1])
    end

    test "unknown values pass through unchanged" do
      ref = make_ref()
      assert DataLayer.wrap_typed(ref, :r, %{}) == ref
    end
  end

  describe "attr_cql_type_map/1 and resolve helpers" do
    test "maps atom and string keys to CQL types" do
      map = DataLayer.attr_cql_type_map(TypedResource)

      assert map[:id] == "uuid"
      assert map["id"] == "uuid"
      assert map[:name] == "text"
      assert map[:score] == "double"
      assert map[:tags] == "list<text>"
    end

    test "returns an empty map for non-resources" do
      assert DataLayer.attr_cql_type_map(String) == %{}
    end

    test "composite pk resource maps every attribute" do
      map = DataLayer.attr_cql_type_map(TestResourceCompositePK)
      assert map[:group_id] == "uuid"
      assert map[:order] == "bigint"
    end
  end

  describe "uuid_attribute_names/1" do
    test "detects uuid family attributes including string aliases" do
      names = DataLayer.uuid_attribute_names(TypedResource)

      assert MapSet.member?(names, :id)
      assert MapSet.member?(names, "id")
      assert MapSet.member?(names, :v7)
      refute MapSet.member?(names, :name)
    end

    test "returns empty set for non-resources" do
      assert DataLayer.uuid_attribute_names(String) == %MapSet{}
    end
  end

  describe "transaction callbacks" do
    test "in_transaction? is always false" do
      refute DataLayer.in_transaction?(TestResource)
    end

    test "transaction returns {:ok, result} for a successful function" do
      assert DataLayer.transaction(TestResource, fn -> :value end) == {:ok, :value}
    end

    test "transaction converts raised exceptions into Ash errors" do
      assert {:error, error} = DataLayer.transaction(TestResource, fn -> raise "boom" end)

      assert Exception.message(error) =~ "boom"
    end

    test "rollback is a no-op returning :ok" do
      assert DataLayer.rollback(TestResource, :reason) == :ok
    end

    test "prefer_transaction? reflects the LWT setting" do
      refute DataLayer.prefer_transaction?(TestResource)
      assert DataLayer.prefer_transaction?(BaseFilteredResource)
      refute DataLayer.prefer_transaction_for_atomic_updates?(TestResource)
      assert DataLayer.prefer_transaction_for_atomic_updates?(BaseFilteredResource)
    end
  end

  describe "to_ash_record_public/2" do
    test "builds a resource struct from an atom-keyed map" do
      id = Ash.UUID.generate()

      record =
        DataLayer.to_ash_record_public(
          %{"unexpected" => 1, id: id, name: "n"},
          TestResource
        )

      assert %TestResource{} = record
      assert record.id == id
      assert record.name == "n"
    end

    test "falls back to string keys when atom keys are missing" do
      id = Ash.UUID.generate()

      record = DataLayer.to_ash_record_public(%{"id" => id, "name" => "str"}, TestResource)

      assert record.id == id
      assert record.name == "str"
    end

    test "converts atom-typed attributes from strings" do
      record =
        DataLayer.to_ash_record_public(
          %{id: Ash.UUID.generate(), status: "active"},
          TypedResource
        )

      assert record.status == :active
    end

    test "accepts tuple records via the fallback attribute-order branch" do
      record = DataLayer.to_ash_record_public({Ash.UUID.generate(), "x", nil}, TestResource)

      assert %TestResource{} = record
      assert record.name == "x"
    end
  end

  describe "maybe_apply_in_memory_sort_public/3" do
    test "sorts records by the requested field when order was dropped" do
      records = [%{id: 1, n: 3}, %{id: 2, n: 1}, %{id: 3, n: 2}]

      sorted = DataLayer.maybe_apply_in_memory_sort_public(records, [{:n, :asc}], true)

      assert Enum.map(sorted, & &1.n) == [1, 2, 3]
    end

    test "returns records unchanged when sorting was not dropped" do
      records = [%{id: 2}, %{id: 1}]
      assert DataLayer.maybe_apply_in_memory_sort_public(records, [], false) == records
    end
  end

  describe "query callback shims" do
    test "filter prepends filters and rewrites OR-to-IN" do
      q = %AshScylla.Query{repo: FakeRepoShim, table: "t"}

      {:ok, %{filters: [rewritten]}} =
        DataLayer.filter(q, %{op: :or, left: %{name: :a, op: :eq, right: %{value: 1}},
        right: %{name: :a, op: :eq, right: %{value: 2}}}, TestResource)

      assert rewritten.operator == :in
      assert rewritten.right.value == [1, 2]

      {:ok, %{filters: [kept | _]}} =
        DataLayer.filter(q, %{op: :eq, name: :a, right: %{value: 1}}, TestResource)

      assert kept.op == :eq
    end

    test "select, sort, limit, lock, and set_context update the query struct" do
      q = %AshScylla.Query{repo: FakeRepoShim, table: "t"}

      assert {:ok, %{select: [:a, :b]}} = DataLayer.select(q, [:a, :b], TestResource)
      assert {:ok, %{sorts: sorts}} = DataLayer.sort(q, [asc: :a], TestResource)
      assert sorts != []
      assert {:ok, %{limit: 10}} = DataLayer.limit(q, 10, TestResource)
      assert {:ok, ^q} = DataLayer.lock(q, :for_update, TestResource)

      assert {:ok, %{context: context}} =
               DataLayer.set_context(TestResource, q, %{a: 1})

      assert context == %{a: 1}

      merged_q = %{q | context: %{b: 2}}

      assert {:ok, %{context: context}} =
               DataLayer.set_context(TestResource, merged_q, %{a: 1})

      assert context == %{a: 1, b: 2}
    end

    test "distinct allows partition-key-only columns and rejects others" do
      q = %AshScylla.Query{repo: FakeRepoShim, table: "t"}

      assert {:ok, %{select: [:id]}} = DataLayer.distinct(q, [:id], TestResource)

      assert {:error, _} = DataLayer.distinct(q, [:name], TestResource)
    end

    test "set_tenant stores the tenant for context strategy" do
      q = %AshScylla.Query{repo: FakeRepoShim, table: "t"}

      assert {:ok, %{tenant: "tenant-1"}} =
               DataLayer.set_tenant(ContextMultitenantResource, q, "tenant-1")
    end

    test "set_tenant adds an equality filter for attribute strategy" do
      q = %AshScylla.Query{repo: FakeRepoShim, table: "t"}

      assert {:ok, %{tenant: nil, filters: [%{name: :org_id} | _]}} =
               DataLayer.set_tenant(AttributeMultitenantResource, q, "org-42")
    end

    test "set_tenant falls back to tenant storage when no attribute is configured" do
      q = %AshScylla.Query{repo: FakeRepoShim, table: "t"}

      assert {:ok, %{tenant: "tenant-9"}} =
               DataLayer.set_tenant(AttributeMultitenantNoAttrResource, q, "tenant-9")

      assert {:ok, %{tenant: "tenant-9"}} =
               DataLayer.set_tenant(nil, q, "tenant-9")
    end
  end

  describe "transform_query/1" do
    test "applies base_filter and default_context from the DSL" do
      query = Ash.Query.new(BaseFilteredResource)
      transformed = DataLayer.transform_query(query)

      assert transformed.filter != nil
      assert transformed.context[:tenant] == "acme"
    end

    test "leaves plain queries untouched" do
      query = Ash.Query.new(TestResource)
      assert DataLayer.transform_query(query) == query
    end
  end

  describe "table naming" do
    test "source uses the DSL table" do
      assert DataLayer.source(TestResource) == "test_resource"
    end

    test "qualified_table prefixes the keyspace when configured" do
      assert DataLayer.qualified_table(TestResource) == "ash_scylla_test.test_resource"
    end

    test "qualified_table falls back to the repo keyspace when the resource has none" do
      assert DataLayer.qualified_table(TestResourceNoKeyspace) ==
               "ash_scylla_dev.#{DataLayer.source(TestResourceNoKeyspace)}"
    end

    test "resources without a DSL table derive their name from the module" do
      assert DataLayer.source(TypedResource) == "dl_typed"
      assert DataLayer.resolve_table_name(ContextMultitenantResource) == "dl_mt_context"
    end

    test "can? reports supported features" do
      assert DataLayer.can?(TestResource, :create)
      assert DataLayer.can?(TestResource, :read)
      assert DataLayer.can?(TestResource, :update)
      assert DataLayer.can?(TestResource, :destroy)
      assert DataLayer.can?(TestResource, :composite_primary_key)
      assert DataLayer.can?(TestResource, {:atomic, :update})
      assert DataLayer.can?(TestResource, {:atomic, :upsert})
      assert DataLayer.can?(TestResource, {:aggregate, :count})
      assert DataLayer.can?(TestResource, {:query_aggregate, :sum})
      assert DataLayer.can?(TestResource, :upsert)
      assert DataLayer.can?(TestResource, :transact)
      assert DataLayer.can?(TestResource, {:aggregate_relationship, :parent})

      refute DataLayer.can?(TestResource, :lateral_join)
      refute DataLayer.can?(TestResource, :lock)
      refute DataLayer.can?(TestResource, :offset)
      refute DataLayer.can?(TestResource, {:join, TestResource})
      refute DataLayer.can?(TestResource, {:lateral_join, []})
      refute DataLayer.can?(TestResource, {:filter_relationship, :parent})
      refute DataLayer.can?(TestResource, {:exists, :unrelated})
      refute DataLayer.can?(TestResource, {:aggregate, :custom_kind})
      refute DataLayer.can?(TestResource, {:query_aggregate, :median})
      refute DataLayer.can?(TestResource, :some_unknown_feature)
      refute DataLayer.can?(TestResource, {"tuple", "feature"})
    end
  end
end
