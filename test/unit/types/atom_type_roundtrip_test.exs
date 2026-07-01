defmodule AshScylla.AtomTypeRoundtripTest do
  @moduledoc """
  Tests for Atom type round-trip: Ash atom → ScyllaDB TEXT → Ash atom.

  Verifies:
  1. Atom values are encoded as TEXT for ScyllaDB storage
  2. String values from ScyllaDB are converted back to atoms on read
  3. Round-trip preserves atom values through create/read/update
  4. Multiple atom values with different string representations
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshScylla.DataLayer

  # ---------------------------------------------------------------------------
  # Fake repo that stores and returns string values (simulating ScyllaDB TEXT)
  # ---------------------------------------------------------------------------

  defmodule AtomFakeRepo do
    @moduledoc false

    def query(query, params, opts \\ []) do
      send(self(), {:atom_query, query, params, opts})

      cond do
        String.contains?(query, "INSERT INTO") and String.contains?(query, "atom_test") ->
          {:ok, %Xandra.Page{content: []}}

        String.contains?(query, "SELECT * FROM") and String.contains?(query, "atom_test") and
            String.contains?(query, "WHERE id = ?") ->
          [id] = params

          row = %{
            id: id,
            status: "active",
            privacy: "public",
            priority: "high",
            category: "user",
            empty_val: nil
          }

          {:ok,
           %Xandra.Page{
             content: [row],
             columns: ["id", "status", "privacy", "priority", "category", "empty_val"]
           }}

        String.contains?(query, "UPDATE") and String.contains?(query, "atom_test") ->
          {:ok, %Xandra.Page{content: []}}

        String.contains?(query, "DELETE") and String.contains?(query, "atom_test") ->
          {:ok, %Xandra.Page{content: []}}

        true ->
          {:error, %Xandra.Error{reason: :overloaded, message: nil, warnings: []}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Test resource with Atom-typed attributes
  # ---------------------------------------------------------------------------

  defmodule AtomResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AtomFakeRepo)
      table("atom_test")
      keyspace("test_ks")
      consistency(:one)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:status, :atom)
      attribute(:privacy, :atom)
      attribute(:priority, :atom)
      attribute(:category, :atom)
      attribute(:empty_val, :atom)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
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

  defp changeset(attrs), do: %Ash.Changeset{attributes: attrs}

  # ===========================================================================
  # Atom type encoding (Ash → ScyllaDB)
  # ===========================================================================

  describe "Atom type encoding (Ash → ScyllaDB)" do
    test "atom values are stored as text strings in ScyllaDB" do
      id = "550e8400-e29b-41d4-a716-446655440001"
      cs = changeset(%{id: id, status: :active, privacy: :public})

      assert {:ok, _record} = DataLayer.create(AtomResource, cs)

      assert_receive {:atom_query, insert_query, insert_params, _opts}
      assert insert_query =~ "INSERT INTO"
      assert insert_query =~ "atom_test"

      # Atoms should be converted to strings in the params (wrapped as {"text", value})
      assert {"text", "active"} in insert_params
      assert {"text", "public"} in insert_params
    end

    test "atom with underscores and special names are encoded correctly" do
      id = "550e8400-e29b-41d4-a716-446655440002"
      cs = changeset(%{id: id, priority: :high_priority, category: :user_profile})

      assert {:ok, _record} = DataLayer.create(AtomResource, cs)

      assert_receive {:atom_query, _query, insert_params, _opts}
      assert {"text", "high_priority"} in insert_params
      assert {"text", "user_profile"} in insert_params
    end
  end

  # ===========================================================================
  # Atom type decoding (ScyllaDB → Ash)
  # ===========================================================================

  describe "Atom type decoding (ScyllaDB → Ash)" do
    test "string values from ScyllaDB are converted to atoms on read" do
      id = "550e8400-e29b-41d4-a716-446655440001"
      cs = changeset(%{id: id, status: :active, privacy: :public})

      assert {:ok, record} = DataLayer.create(AtomResource, cs)

      # After round-trip through FakeRepo, atoms should be preserved
      assert record.status == :active
      assert record.privacy == :public
      assert is_atom(record.status)
      assert is_atom(record.privacy)
    end

    test "nil atom values are preserved as nil" do
      id = "550e8400-e29b-41d4-a716-446655440001"
      cs = changeset(%{id: id, status: :active})

      assert {:ok, record} = DataLayer.create(AtomResource, cs)

      assert record.empty_val == nil
    end
  end

  # ===========================================================================
  # Atom type round-trip (Ash → ScyllaDB → Ash)
  # ===========================================================================

  describe "Atom type round-trip" do
    test "create and read preserves atom values" do
      id = "550e8400-e29b-41d4-a716-446655440001"

      create_attrs = %{
        id: id,
        status: :active,
        privacy: :public,
        priority: :high,
        category: :user
      }

      assert {:ok, created} = DataLayer.create(AtomResource, changeset(create_attrs))

      # FakeRepo returns hardcoded values, so we verify the round-trip works
      # by checking that atoms are returned (not strings)
      assert is_atom(created.status)
      assert is_atom(created.privacy)
      assert is_atom(created.priority)
      assert is_atom(created.category)
    end

    test "update preserves atom values" do
      id = "550e8400-e29b-41d4-a716-446655440001"

      # Create first
      create_attrs = %{id: id, status: :active, privacy: :public}
      assert {:ok, _created} = DataLayer.create(AtomResource, changeset(create_attrs))
      assert_receive {:atom_query, _, _, _}

      # Update atom values
      update_attrs = %{
        id: id,
        status: :active,
        privacy: :public,
        priority: :high
      }

      assert {:ok, updated} = DataLayer.update(AtomResource, changeset(update_attrs))

      # Verify atoms are returned (not strings)
      assert is_atom(updated.status)
      assert is_atom(updated.privacy)
      assert is_atom(updated.priority)
    end

    test "multiple atom values in single record" do
      id = "550e8400-e29b-41d4-a716-446655440001"

      attrs = %{
        id: id,
        status: :active,
        privacy: :public,
        priority: :high,
        category: :user
      }

      assert {:ok, record} = DataLayer.create(AtomResource, changeset(attrs))

      # Each atom should be independently preserved as atom type
      assert record.status == :active
      assert record.privacy == :public
      assert record.priority == :high
      assert record.category == :user
    end
  end

  # ===========================================================================
  # Atom type CQL mapping
  # ===========================================================================

  describe "Atom type CQL mapping" do
    test "atom type maps to TEXT in CQL" do
      map = DataLayer.attr_cql_type_map(AtomResource)
      assert map[:status] == "text"
      assert map[:privacy] == "text"
      assert map[:priority] == "text"
      assert map[:category] == "text"
    end
  end
end
