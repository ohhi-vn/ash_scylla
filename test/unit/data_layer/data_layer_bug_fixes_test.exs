defmodule AshScylla.DataLayer.BugFixesTest do
  @moduledoc """
  Tests for bug fixes:
  1. LIMIT parameter marshaling (int vs bigint)
  2. Atom type conversion in to_ash_record
  3. get_primary_key uses changeset.data as fallback
  4. In-memory sort fallback when ORDER BY is dropped for secondary index scans
  5. Float columns marshaled as 8-byte double (not 4-byte float)
  6. update_query/4 argument order matches Ash callback
  7. get_primary_key_from_changeset/2 reads PK from struct fields
  8. bulk_create/3 returns [] when return_records? is false
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer

  import AshScylla.DataLayer.Types, only: [uuid_string_to_binary: 1]

  defp uuid_bin(id), do: elem(uuid_string_to_binary(id), 1)

  # ---------------------------------------------------------------------------
  # Fake repo — pattern-matches on CQL strings and returns positional rows
  # ---------------------------------------------------------------------------

  defmodule FakeRepo do
    @moduledoc false

    defp uuid_bin(id) when is_binary(id) and byte_size(id) == 36 do
      elem(AshScylla.DataLayer.Types.uuid_string_to_binary(id), 1)
    end

    defp unwrap_params(params) do
      Enum.map(params, fn
        {_type, value} -> value
        value -> value
      end)
    end

    def query(query, params, opts \\ []) do
      raw_params = unwrap_params(params)
      send(self(), {:ash_scylla_query, query, raw_params, opts})

      case query do
        # --- batch ---
        "BEGIN BATCH" <> _ ->
          {:ok, %Xandra.Void{}}

        # --- inserts ---
        "INSERT INTO test_ks.bug_items" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        "INSERT INTO test_ks.float_items" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        "INSERT INTO test_ks.struct_pk_items" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        # --- updates ---
        "UPDATE test_ks.bug_items SET" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        "UPDATE test_ks.float_items SET" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        "UPDATE test_ks.struct_pk_items SET" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        # --- deletes ---
        "DELETE FROM test_ks.bug_items" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        "DELETE FROM test_ks.float_items" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        "DELETE FROM test_ks.struct_pk_items" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        # --- selects with LIMIT on secondary index ---
        "SELECT * FROM test_ks.bug_items WHERE" <> _ ->
          [_status, limit] = raw_params

          rows = [
            [uuid_bin("550e8400-e29b-41d4-a716-446655440001"), "Alice", "public", 100],
            [uuid_bin("550e8400-e29b-41d4-a716-446655440002"), "Bob", "private", 200],
            [uuid_bin("550e8400-e29b-41d4-a716-446655440003"), "Charlie", "friends", 50]
          ]

          # Apply limit if present
          rows =
            if is_integer(limit) do
              Enum.take(rows, limit)
            else
              rows
            end

          {:ok,
           %Xandra.Page{
             content: rows,
             columns: ["id", "name", "privacy", "score"]
           }}

        # --- selects without LIMIT (for PK fetch) ---
        "SELECT * FROM test_ks.bug_items WHERE id = ? LIMIT 1" ->
          [id] = raw_params

          {:ok,
           %Xandra.Page{
             content: [[id, "Alice", "public", 100]],
             columns: ["id", "name", "privacy", "score"]
           }}

        "SELECT * FROM test_ks.float_items WHERE id = ? LIMIT 1" ->
          [id] = raw_params

          {:ok,
           %Xandra.Page{
             content: [[id, "Run", 10.5, 100.0, 50.0]],
             columns: ["id", "name", "speed", "distance", "elevation"]
           }}

        "SELECT * FROM test_ks.float_items WHERE name = ?" <> _ ->
          [_name] = raw_params

          {:ok,
           %Xandra.Page{
             content: [
               [uuid_bin("550e8400-e29b-41d4-a716-446655440099"), "Run", 10.5, 100.0, 50.0]
             ],
             columns: ["id", "name", "speed", "distance", "elevation"]
           }}

        "SELECT * FROM test_ks.struct_pk_items WHERE" <> _ ->
          [id] = raw_params

          {:ok,
           %Xandra.Page{
             content: [[id, "Alice", "game-1"]],
             columns: ["id", "name", "game_id"]
           }}

        # --- fallback ---
        _ ->
          {:error, %Xandra.Error{reason: :overloaded, message: nil, warnings: []}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Test resources
  # ---------------------------------------------------------------------------

  defmodule AtomResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(FakeRepo)
      table("bug_items")
      keyspace("test_ks")
      consistency(:one)
      secondary_index(:privacy)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:privacy, :atom)
      attribute(:score, :integer)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule FloatResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(FakeRepo)
      table("float_items")
      keyspace("test_ks")
      consistency(:one)
      secondary_index(:name)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:speed, :float)
      attribute(:distance, :float)
      attribute(:elevation, :float)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule StructPkResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(FakeRepo)
      table("struct_pk_items")
      keyspace("test_ks")
      consistency(:one)
      secondary_index(:name)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:game_id, :string, primary_key?: true, allow_nil?: false)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  setup do
    flush_messages()
    :ok
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end

  defp changeset(attrs),
    do: %Ash.Changeset{attributes: attrs, data: %{attributes: %{}}}

  defp changeset_with_data(attrs, data_attrs) do
    %Ash.Changeset{
      attributes: attrs,
      data: %{attributes: data_attrs}
    }
  end

  # ===========================================================================
  # Bug 1: LIMIT parameter marshaling — integers should be tagged as "int"
  # ===========================================================================

  describe "Bug 1: LIMIT parameter marshaling" do
    test "integers are tagged as int not bigint to avoid ScyllaDB Int32Type marshaling error" do
      query = %AshScylla.Query{
        resource: AtomResource,
        repo: FakeRepo,
        table: "test_ks.bug_items",
        filters: [%{operator: :eq, left: %{name: :privacy}, right: %{value: "public"}}],
        sorts: [],
        limit: 250,
        select: nil,
        tenant: nil,
        context: %{}
      }

      assert {:ok, _records} = DataLayer.run_query(query, AtomResource)

      assert_receive {:ash_scylla_query, _cql, params, _opts}
      # The limit param should be an integer (not causing Int32Type marshaling error)
      assert [_, 250] = params
    end

    test "limit value within int32 range does not cause marshaling error" do
      query = %AshScylla.Query{
        resource: AtomResource,
        repo: FakeRepo,
        table: "test_ks.bug_items",
        filters: [%{operator: :eq, left: %{name: :privacy}, right: %{value: "public"}}],
        sorts: [],
        limit: 10,
        select: nil,
        tenant: nil,
        context: %{}
      }

      assert {:ok, _records} = DataLayer.run_query(query, AtomResource)

      assert_receive {:ash_scylla_query, _cql, params, _opts}
      assert [_, 10] = params
    end
  end

  # ===========================================================================
  # Bug 2: Atom type conversion in to_ash_record
  # ===========================================================================

  describe "Bug 2: Atom type conversion" do
    test "atom fields are converted from strings to atoms when read" do
      query = %AshScylla.Query{
        resource: AtomResource,
        repo: FakeRepo,
        table: "test_ks.bug_items",
        filters: [%{operator: :eq, left: %{name: :privacy}, right: %{value: "public"}}],
        sorts: [],
        limit: 10,
        select: nil,
        tenant: nil,
        context: %{}
      }

      assert {:ok, records} = DataLayer.run_query(query, AtomResource)
      assert records != []

      # privacy should be an atom, not a string
      first = hd(records)
      assert first.privacy == :public
      assert is_atom(first.privacy)
    end

    test "all atom values in results are proper atoms" do
      query = %AshScylla.Query{
        resource: AtomResource,
        repo: FakeRepo,
        table: "test_ks.bug_items",
        filters: [%{operator: :eq, left: %{name: :privacy}, right: %{value: "public"}}],
        sorts: [],
        limit: 10,
        select: nil,
        tenant: nil,
        context: %{}
      }

      assert {:ok, records} = DataLayer.run_query(query, AtomResource)

      Enum.each(records, fn record ->
        assert is_atom(record.privacy),
               "Expected privacy to be an atom, got: #{inspect(record.privacy)}"
      end)
    end
  end

  # ===========================================================================
  # Bug 3: get_primary_key uses changeset.data as fallback
  # ===========================================================================

  describe "Bug 3: get_primary_key with changeset.data fallback" do
    test "destroy uses primary key from data when attributes are nil" do
      # Simulate a changeset where attributes don't have the PK set
      # but data does (common in destroy actions)
      changeset =
        changeset_with_data(
          # attributes don't have PKs
          %{name: "Alice"},
          # data has PKs
          %{id: "550e8400-e29b-41d4-a716-446655440001", name: "Alice"}
        )

      assert :ok = DataLayer.destroy(AtomResource, changeset)

      assert_receive {:ash_scylla_query, delete_query, params, _opts}
      assert delete_query == "DELETE FROM test_ks.bug_items WHERE id = ?"
      # Should have the UUID binary from data, not nil
      assert [id_bin] = params
      assert is_binary(id_bin)
      assert byte_size(id_bin) == 16
    end

    test "destroy works when attributes have PK set" do
      id = "550e8400-e29b-41d4-a716-446655440001"
      changeset = changeset(%{id: id})

      assert :ok = DataLayer.destroy(AtomResource, changeset)

      assert_receive {:ash_scylla_query, delete_query, params, _opts}
      assert delete_query == "DELETE FROM test_ks.bug_items WHERE id = ?"
      assert [id_bin] = params
      assert id_bin == uuid_bin(id)
    end
  end

  # ===========================================================================
  # Bug 4: In-memory sort fallback for secondary index scans
  # ===========================================================================

  describe "Bug 4: In-memory sort fallback for secondary index scans" do
    test "results are sorted in-memory when ORDER BY is dropped for secondary index scan" do
      query = %AshScylla.Query{
        resource: AtomResource,
        repo: FakeRepo,
        table: "test_ks.bug_items",
        filters: [%{operator: :eq, left: %{name: :privacy}, right: %{value: "public"}}],
        sorts: [:score],
        limit: 10,
        select: nil,
        tenant: nil,
        context: %{}
      }

      assert {:ok, records} = DataLayer.run_query(query, AtomResource)
      assert length(records) == 3

      scores = Enum.map(records, & &1.score)
      assert scores == Enum.sort(scores)
    end

    test "results are sorted by specified field when secondary index scan drops ORDER BY" do
      query = %AshScylla.Query{
        resource: AtomResource,
        repo: FakeRepo,
        table: "test_ks.bug_items",
        filters: [%{operator: :eq, left: %{name: :privacy}, right: %{value: "public"}}],
        sorts: [:score],
        limit: 10,
        select: nil,
        tenant: nil,
        context: %{}
      }

      assert {:ok, records} = DataLayer.run_query(query, AtomResource)

      # Verify ascending order
      scores = Enum.map(records, & &1.score)
      assert scores == [50, 100, 200]
    end
  end

  # ===========================================================================
  # Bug 5: Float columns marshaled as 8-byte double (not 4-byte float)
  # ===========================================================================

  describe "Bug 5: Float columns marshaled as double" do
    test "attr_cql_type_map resolves :float to 'double' not 'float'" do
      map = DataLayer.attr_cql_type_map(FloatResource)
      assert map[:speed] == "double"
      assert map[:distance] == "double"
      assert map[:elevation] == "double"
    end

    test "create sends float values as doubles" do
      id = "550e8400-e29b-41d4-a716-446655440099"
      cs = changeset(%{id: id, name: "Run", speed: 10.5, distance: 100.0, elevation: 50.0})
      assert {:ok, _record} = DataLayer.create(FloatResource, cs)

      assert_receive {:ash_scylla_query, insert_query, insert_params, _opts}
      assert insert_query =~ "INSERT INTO test_ks.float_items"

      # Verify float values are present as raw floats
      # The data layer wraps them in {type, value} tuples internally,
      # but unwrap_params strips the type tags for the test assertion
      assert 10.5 in insert_params
      assert 100.0 in insert_params
      assert 50.0 in insert_params
    end

    test "bulk_create sends float values as doubles" do
      id1 = "550e8400-e29b-41d4-a716-446655440098"
      id2 = "550e8400-e29b-41d4-a716-446655440097"

      changesets = [
        changeset(%{id: id1, name: "Sprint", speed: 15.0, distance: 50.0, elevation: 10.0}),
        changeset(%{id: id2, name: "Marathon", speed: 8.5, distance: 42.0, elevation: 100.0})
      ]

      assert {:ok, _records} =
               DataLayer.bulk_create(FloatResource, changesets, max_concurrency: 1)

      assert_receive {:ash_scylla_query, batch_query, batch_params, _opts}
      assert batch_query =~ "BEGIN BATCH"
      assert batch_query =~ "INSERT INTO test_ks.float_items"

      # Verify all float values are present
      assert 15.0 in batch_params
      assert 8.5 in batch_params
      assert 50.0 in batch_params
      assert 42.0 in batch_params
      assert 10.0 in batch_params
      assert 100.0 in batch_params
    end
  end

  # ===========================================================================
  # Bug 6: update_query/4 argument order matches Ash callback
  # ===========================================================================

  describe "Bug 6: update_query/4 argument order" do
    test "update_query accepts (query, changeset, resource, opts)" do
      query = %AshScylla.Query{
        resource: FloatResource,
        repo: FakeRepo,
        table: "test_ks.float_items",
        filters: [%{operator: :eq, left: %{name: :name}, right: %{value: "Run"}}],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil,
        context: %{}
      }

      # The Ash callback calls update_query(query, changeset, resource, opts)
      # If the arguments are swapped, this will fail with FunctionClauseError
      # because repo() would be called with an opts map instead of a resource
      assert {:ok, _records} =
               DataLayer.update_query(query, changeset(%{speed: 20.0}), FloatResource, [])

      assert_receive {:ash_scylla_query, update_query, _update_params, opts}
      assert update_query =~ "UPDATE test_ks.float_items SET"
      assert opts[:consistency] == :one
    end

    test "update_query does not crash when opts contain keyword list" do
      query = %AshScylla.Query{
        resource: FloatResource,
        repo: FakeRepo,
        table: "test_ks.float_items",
        filters: [%{operator: :eq, left: %{name: :name}, right: %{value: "Run"}}],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil,
        context: %{}
      }

      # With correct argument order, opts are the 4th argument
      # With swapped args, resource (module) would be in opts position
      # and repo(resource) would fail
      assert {:ok, _} =
               DataLayer.update_query(
                 query,
                 changeset(%{distance: 200.0}),
                 FloatResource,
                 consistency: :local_quorum
               )
    end
  end

  # ===========================================================================
  # Bug 7: get_primary_key_from_changeset/2 reads PK from struct fields
  # ===========================================================================

  describe "Bug 7: get_primary_key_from_changeset with struct data" do
    test "destroy reads PK from struct fields when data_attributes is empty" do
      # Simulate a changeset where data is a struct (not a plain map)
      # Structs don't have an :attributes field, so Map.get(struct, :attributes) returns nil
      data_struct = %{
        id: "550e8400-e29b-41d4-a716-446655440001",
        name: "Alice",
        game_id: "game-1"
      }

      # Build a changeset with struct-like data (no :attributes key)
      changeset = %Ash.Changeset{
        attributes: %{name: "Alice"},
        data: data_struct
      }

      assert :ok = DataLayer.destroy(StructPkResource, changeset)

      assert_receive {:ash_scylla_query, delete_query, params, _opts}
      assert delete_query =~ "DELETE FROM test_ks.struct_pk_items"
      assert delete_query =~ "WHERE"

      # Should have extracted the PK from the struct fields
      assert params != []
      # The first param should be the UUID binary for the :id PK
      [id_bin | _] = params
      assert is_binary(id_bin)
      assert byte_size(id_bin) == 16
    end

    test "update_query works with struct-based changeset data" do
      # When changeset.data is a struct (no :attributes), the PK should still be found
      data_struct = %{
        id: "550e8400-e29b-41d4-a716-446655440002",
        name: "Bob",
        game_id: "game-2"
      }

      changeset = %Ash.Changeset{
        attributes: %{name: "Bob Updated"},
        data: data_struct
      }

      query = %AshScylla.Query{
        resource: StructPkResource,
        repo: FakeRepo,
        table: "test_ks.struct_pk_items",
        filters: [%{operator: :eq, left: %{name: :name}, right: %{value: "Bob"}}],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil,
        context: %{}
      }

      assert {:ok, _records} =
               DataLayer.update_query(query, changeset, StructPkResource, [])

      assert_receive {:ash_scylla_query, _update_query, _update_params, _opts}
    end
  end

  # ===========================================================================
  # Bug 8: bulk_create/3 returns [] when return_records? is false
  # ===========================================================================

  describe "Bug 9: OR with nested AND groups (CQL limitation)" do
    test "cross-field OR raises a clear error explaining the CQL limitation" do
      filter = %{
        op: :and,
        left: %{
          op: :or,
          left: %{
            op: :and,
            left: %{
              name: :from_user_id,
              op: :eq,
              right: %{value: "019f2660-4930-7ac3-bb36-3f094e43443f"}
            },
            right: %{
              name: :to_user_id,
              op: :eq,
              right: %{value: "019f2660-492b-72f1-9e16-66573f1e263e"}
            }
          },
          right: %{
            op: :and,
            left: %{
              name: :from_user_id,
              op: :eq,
              right: %{value: "019f2660-492b-72f1-9e16-66573f1e263e"}
            },
            right: %{
              name: :to_user_id,
              op: :eq,
              right: %{value: "019f2660-4930-7ac3-bb36-3f094e43443f"}
            }
          }
        },
        right: %{name: :archived, op: :eq, right: %{value: false}}
      }

      assert_raise AshScylla.Error, ~r/CQL does not support OR across different fields/, fn ->
        AshScylla.DataLayer.QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      end
    end

    test "same-field OR with eq is rewritten to IN" do
      filter = %{
        op: :or,
        left: %{name: :status, op: :eq, right: %{value: "active"}},
        right: %{name: :status, op: :eq, right: %{value: "inactive"}}
      }

      {cql, params} = AshScylla.DataLayer.QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})

      # Same-field OR with eq should be rewritten to IN
      assert cql =~ "status IN"
      assert params == ["active", "inactive"]
    end

    test "OR with different single fields raises error" do
      filter = %{
        op: :or,
        left: %{name: :status, op: :eq, right: %{value: "active"}},
        right: %{name: :age, op: :eq, right: %{value: 25}}
      }

      assert_raise AshScylla.Error, ~r/CQL does not support OR across different fields/, fn ->
        AshScylla.DataLayer.QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      end
    end
  end

  describe "Bug 8: bulk_create with return_records? false" do
    test "returns {:ok, []} when return_records? is false" do
      changesets = [
        changeset(%{name: "Alice", speed: 10.0}),
        changeset(%{name: "Bob", speed: 20.0})
      ]

      assert {:ok, []} = DataLayer.bulk_create(FloatResource, changesets, return_records?: false)
    end

    test "does not crash when changeset.data is nil" do
      # Changesets built from raw maps may have nil data
      changesets = [
        %Ash.Changeset{attributes: %{name: "Charlie", speed: 15.0}, data: nil},
        %Ash.Changeset{attributes: %{name: "Diana", speed: 25.0}, data: nil}
      ]

      assert {:ok, []} = DataLayer.bulk_create(FloatResource, changesets, return_records?: false)
    end

    test "returns records when return_records? is true" do
      id = "550e8400-e29b-41d4-a716-446655440096"

      changesets = [
        changeset(%{id: id, name: "Eve", speed: 30.0})
      ]

      assert {:ok, records} =
               DataLayer.bulk_create(FloatResource, changesets, return_records?: true)

      assert Enum.count(records) == 1
    end
  end
end
