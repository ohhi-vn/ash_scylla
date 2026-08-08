defmodule AshScylla.DataLayer.AtomicUpdateTest do
  use ExUnit.Case, async: false

  alias AshScylla.DataLayer

  # FakeRepo that captures queries for inspection
  defmodule FakeRepo do
    def query(query, params, _opts \\ []) do
      send(self(), {:ash_scylla_query, query, params, []})
      {:ok, %Xandra.Page{content: [], columns: []}}
    end
  end

  # Resource with non-atomic constraints (simulating the real-world scenario)
  defmodule AtomicUpdateResource do
    use Ash.Resource,
      domain: AshScylla.TestDomain,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(FakeRepo)
      table("atomic_items")
      keyspace("test_ks")
      consistency(:one)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:description, :string, public?: true)
      attribute(:location, :string, public?: true)
      create_timestamp(:created_at)
      update_timestamp(:updated_at)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defp uuid_bin(id) do
    {:ok, bin} = AshScylla.DataLayer.Types.uuid_string_to_binary(id)
    bin
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end

  setup do
    flush_messages()
    :ok
  end

  describe "Bug: atomic update with non-atomic constraints" do
    test "update_query extracts values from atomics when attributes is empty" do
      # Simulate a changeset where:
      # - attributes is empty (all fields are non-atomic constraints)
      # - atomics contains the actual values to update
      # - casted_attributes is also empty
      changeset = %Ash.Changeset{
        attributes: %{},
        casted_attributes: %{},
        atomics: [
          name: "Halo Club 3333",
          description: "Test TEst",
          location: "Saigon"
        ],
        data: %AtomicUpdateResource{
          id: "019f92c8-ea99-7193-93a8-d4591edbbd15",
          name: "Halo Club",
          description: "Test TEst",
          location: "Saigon"
        },
        filter: nil
      }

      query = %AshScylla.Query{
        resource: AtomicUpdateResource,
        repo: FakeRepo,
        table: "test_ks.atomic_items",
        filters: [
          %{
            operator: :eq,
            left: %{name: :id},
            right: %{value: "019f92c8-ea99-7193-93a8-d4591edbbd15"}
          }
        ],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil,
        context: %{},
        atomic: nil,
        upsert?: false
      }

      assert {:ok, _} = DataLayer.update_query(query, changeset, AtomicUpdateResource, [])

      assert_received {:ash_scylla_query, update_query, params, _opts}

      # Verify the query has a SET clause with actual values
      assert update_query =~ "UPDATE"
      assert update_query =~ "SET"
      assert update_query =~ "WHERE"

      # Verify SET clause contains the attribute names
      assert update_query =~ "name = ?"
      assert update_query =~ "description = ?"
      assert update_query =~ "location = ?"

      # Verify the query is NOT malformed (no empty SET clause)
      refute update_query =~ "SET  WHERE"
      refute update_query =~ "SET  "
    end

    test "update_query skips UPDATE when no simple values in atomics" do
      # When atomics only contains expressions (like updated_at), skip the UPDATE
      # Use a non-simple value (a map, which is not atom/binary/integer/boolean/float/nil)
      changeset = %Ash.Changeset{
        attributes: %{},
        casted_attributes: %{},
        atomics: [
          updated_at: %{__struct__: Ash.Query.Ref, expression: :now}
        ],
        data: %AshScylla.TestResource{
          id: "019f92c8-ea99-7193-93a8-d4591edbbd15"
        },
        filter: nil
      }

      query = %AshScylla.Query{
        resource: AtomicUpdateResource,
        repo: FakeRepo,
        table: "test_ks.atomic_items",
        filters: [
          %{
            operator: :eq,
            left: %{name: :id},
            right: %{value: "019f92c8-ea99-7193-93a8-d4591edbbd15"}
          }
        ],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil,
        context: %{},
        atomic: nil,
        upsert?: false
      }

      # Should not crash, should skip UPDATE and just return existing records
      assert {:ok, _} = DataLayer.update_query(query, changeset, AtomicUpdateResource, [])

      # Should not have sent an UPDATE query (only a SELECT to return records)
      refute_received {:ash_scylla_query, "UPDATE " <> _, _, _}
    end

    test "update_query uses casted_attributes as fallback when atomics is empty" do
      changeset = %Ash.Changeset{
        attributes: %{},
        casted_attributes: %{
          name: "Updated Name",
          description: "Updated Description"
        },
        atomics: [],
        data: %AshScylla.TestResource{
          id: "019f92c8-ea99-7193-93a8-d4591edbbd15"
        },
        filter: nil
      }

      query = %AshScylla.Query{
        resource: AtomicUpdateResource,
        repo: FakeRepo,
        table: "test_ks.atomic_items",
        filters: [
          %{
            operator: :eq,
            left: %{name: :id},
            right: %{value: "019f92c8-ea99-7193-93a8-d4591edbbd15"}
          }
        ],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil,
        context: %{},
        atomic: nil,
        upsert?: false
      }

      assert {:ok, _} = DataLayer.update_query(query, changeset, AtomicUpdateResource, [])

      assert_received {:ash_scylla_query, update_query, _params, _opts}
      assert update_query =~ "UPDATE"
      assert update_query =~ "name = ?"
      assert update_query =~ "description = ?"
    end

    test "update_query uses changeset.attributes when non-empty" do
      changeset = %Ash.Changeset{
        attributes: %{
          name: "Direct Name",
          location: "Direct Location"
        },
        casted_attributes: %{},
        atomics: [],
        data: %AshScylla.TestResource{
          id: "019f92c8-ea99-7193-93a8-d4591edbbd15"
        },
        filter: nil
      }

      query = %AshScylla.Query{
        resource: AtomicUpdateResource,
        repo: FakeRepo,
        table: "test_ks.atomic_items",
        filters: [
          %{name: :id},
          sorts: [],
          limit: nil,
          select: nil,
          tenant: nil,
          context: %{},
          atomic: nil,
          upsert?: false
        ]
      }

      assert {:ok, _} = DataLayer.update_query(query, changeset, AtomicUpdateResource, [])

      assert_received {:ash_scylla_query, update_query, _params, _opts}
      assert update_query =~ "UPDATE"
      assert update_query =~ "name = ?"
      assert update_query =~ "location = ?"
    end
  end
end
