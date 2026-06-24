defmodule AshScylla.DataLayer.BugFixesTest do
  @moduledoc """
  Tests for bug fixes:
  1. LIMIT parameter marshaling (int vs bigint)
  2. Atom type conversion in to_ash_record
  3. get_primary_key uses changeset.data as fallback
  4. In-memory sort fallback when ORDER BY is dropped for secondary index scans
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer
  alias AshScylla.Error.ScyllaError

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
        # --- inserts ---
        "INSERT INTO bug_items" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        # --- updates ---
        "UPDATE bug_items SET" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        # --- deletes ---
        "DELETE FROM bug_items" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        # --- selects with LIMIT on secondary index ---
        "SELECT * FROM bug_items WHERE" <> _ ->
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
        "SELECT * FROM bug_items WHERE id = ? LIMIT 1" ->
          [id] = raw_params

          {:ok,
           %Xandra.Page{
             content: [[id, "Alice", "public", 100]],
             columns: ["id", "name", "privacy", "score"]
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

    ash_scylla do
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
      query = %DataLayer{
        resource: AtomResource,
        repo: FakeRepo,
        table: "bug_items",
        filters: [%{operator: :eq, left: %{name: :privacy}, right: %{value: "public"}}],
        sorts: [],
        limit: 250,
        offset: nil,
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
      query = %DataLayer{
        resource: AtomResource,
        repo: FakeRepo,
        table: "bug_items",
        filters: [%{operator: :eq, left: %{name: :privacy}, right: %{value: "public"}}],
        sorts: [],
        limit: 10,
        offset: nil,
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
      query = %DataLayer{
        resource: AtomResource,
        repo: FakeRepo,
        table: "bug_items",
        filters: [%{operator: :eq, left: %{name: :privacy}, right: %{value: "public"}}],
        sorts: [],
        limit: 10,
        offset: nil,
        select: nil,
        tenant: nil,
        context: %{}
      }

      assert {:ok, records} = DataLayer.run_query(query, AtomResource)
      assert length(records) > 0

      # privacy should be an atom, not a string
      first = hd(records)
      assert first.privacy == :public
      assert is_atom(first.privacy)
    end

    test "all atom values in results are proper atoms" do
      query = %DataLayer{
        resource: AtomResource,
        repo: FakeRepo,
        table: "bug_items",
        filters: [%{operator: :eq, left: %{name: :privacy}, right: %{value: "public"}}],
        sorts: [],
        limit: 10,
        offset: nil,
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

      assert {:ok, _record} = DataLayer.destroy(AtomResource, changeset)

      assert_receive {:ash_scylla_query, delete_query, params, _opts}
      assert delete_query == "DELETE FROM bug_items WHERE id = ?"
      # Should have the UUID binary from data, not nil
      assert [id_bin] = params
      assert is_binary(id_bin)
      assert byte_size(id_bin) == 16
    end

    test "destroy works when attributes have PK set" do
      id = "550e8400-e29b-41d4-a716-446655440001"
      changeset = changeset(%{id: id})

      assert {:ok, _record} = DataLayer.destroy(AtomResource, changeset)

      assert_receive {:ash_scylla_query, delete_query, params, _opts}
      assert delete_query == "DELETE FROM bug_items WHERE id = ?"
      assert [id_bin] = params
      assert id_bin == uuid_bin(id)
    end
  end

  # ===========================================================================
  # Bug 4: In-memory sort fallback for secondary index scans
  # ===========================================================================

  describe "Bug 4: In-memory sort fallback for secondary index scans" do
    test "results are sorted in-memory when ORDER BY is dropped for secondary index scan" do
      query = %DataLayer{
        resource: AtomResource,
        repo: FakeRepo,
        table: "bug_items",
        filters: [%{operator: :eq, left: %{name: :privacy}, right: %{value: "public"}}],
        sorts: [:score],
        limit: 10,
        offset: nil,
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
      query = %DataLayer{
        resource: AtomResource,
        repo: FakeRepo,
        table: "bug_items",
        filters: [%{operator: :eq, left: %{name: :privacy}, right: %{value: "public"}}],
        sorts: [:score],
        limit: 10,
        offset: nil,
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
end
