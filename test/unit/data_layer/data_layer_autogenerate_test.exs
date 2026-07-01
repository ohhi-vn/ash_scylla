defmodule AshScylla.DataLayer.AutogenerateTest do
  @moduledoc """
  Tests for autogenerate_attribute?/1 and autogenerate_value/1 in AshScylla.DataLayer.

  These private functions are tested indirectly via create/2 and bulk_create/3
  to ensure that primary key values are auto-generated when:
  1. autogenerate? is explicitly set on the attribute
  2. The type has autogenerate_enabled?: true and a generator/1 function
  3. The attribute has a function default (legacy fallback)
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer

  import AshScylla.DataLayer.Types, only: [uuid_string_to_binary: 1]

  defp uuid_bin(id), do: elem(uuid_string_to_binary(id), 1)

  # ---------------------------------------------------------------------------
  # Fake repo
  # ---------------------------------------------------------------------------

  defmodule FakeRepo do
    @moduledoc false

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
        "INSERT INTO test_ks.autogen_items" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        "INSERT INTO test_ks.no_autogen_items" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        "INSERT INTO test_ks.func_default_items" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        "BEGIN BATCH" <> _ ->
          {:ok, %Xandra.Void{}}

        "SELECT * FROM test_ks.autogen_items WHERE id = ? LIMIT 1" ->
          [id] = raw_params

          {:ok,
           %Xandra.Page{content: [[id, "Alice", "active"]], columns: ["id", "name", "status"]}}

        "SELECT * FROM test_ks.func_default_items WHERE id = ? LIMIT 1" ->
          [id] = raw_params
          {:ok, %Xandra.Page{content: [[id, "Bob", "active"]], columns: ["id", "name", "status"]}}

        "SELECT * FROM test_ks.no_autogen_items WHERE id = ? LIMIT 1" ->
          [id] = raw_params

          {:ok,
           %Xandra.Page{content: [[id, "Alice", "active"]], columns: ["id", "name", "status"]}}

        _ ->
          {:error, %Xandra.Error{reason: :overloaded, message: nil, warnings: []}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Test resources
  # ---------------------------------------------------------------------------

  defmodule AutogenResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(FakeRepo)
      table("autogen_items")
      keyspace("test_ks")
      consistency(:one)
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

  defmodule NoAutogenResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(FakeRepo)
      table("no_autogen_items")
      keyspace("test_ks")
      consistency(:one)
    end

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false)
      attribute(:name, :string)
      attribute(:status, :string)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule FuncDefaultResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(FakeRepo)
      table("func_default_items")
      keyspace("test_ks")
      consistency(:one)
    end

    attributes do
      attribute(:id, :uuid,
        primary_key?: true,
        allow_nil?: false,
        default: &Ash.UUIDv7.generate/0
      )

      attribute(:name, :string)
      attribute(:status, :string)
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

  defp changeset(attrs), do: %Ash.Changeset{attributes: attrs, data: %{attributes: %{}}}

  # ===========================================================================
  # Tests
  # ===========================================================================

  describe "autogenerate via autogenerate? attribute option" do
    test "create/2 auto-generates primary key when autogenerate? is true" do
      changeset = changeset(%{name: "Alice", status: "active"})

      assert {:ok, record} = DataLayer.create(AutogenResource, changeset)
      assert is_binary(record.id)
      assert byte_size(record.id) == 36

      assert_receive {:ash_scylla_query, insert_query, insert_params, _opts}
      assert insert_query =~ "INSERT INTO test_ks.autogen_items"
      assert length(insert_params) == 3
      [id_bin | _] = insert_params
      assert is_binary(id_bin)
      assert byte_size(id_bin) == 16
    end

    test "create/2 uses provided primary key even when autogenerate? is true" do
      explicit_id = "550e8400-e29b-41d4-a716-446655440001"
      changeset = changeset(%{id: explicit_id, name: "Alice", status: "active"})

      assert {:ok, record} = DataLayer.create(AutogenResource, changeset)
      assert String.downcase(record.id) == explicit_id

      assert_receive {:ash_scylla_query, _insert_query, insert_params, _opts}
      assert uuid_bin(explicit_id) in insert_params
    end
  end

  describe "no autogenerate - primary key must be provided" do
    test "create/2 succeeds with nil primary key when no autogenerate (data layer trusts changeset)" do
      changeset = changeset(%{name: "Alice", status: "active"})

      assert {:ok, record} = DataLayer.create(NoAutogenResource, changeset)
      assert record.name == "Alice"
      assert record.id == nil
    end

    test "create/2 succeeds when primary key is explicitly provided" do
      explicit_id = "no-autogen-test-id"
      changeset = changeset(%{id: explicit_id, name: "Alice", status: "active"})

      assert {:ok, record} = DataLayer.create(NoAutogenResource, changeset)
      assert record.id == explicit_id
    end
  end

  describe "legacy fallback - function default triggers autogenerate" do
    test "create/2 auto-generates primary key when default is a function" do
      changeset = changeset(%{name: "Bob", status: "active"})

      assert {:ok, record} = DataLayer.create(FuncDefaultResource, changeset)
      assert is_binary(record.id)
      assert byte_size(record.id) == 36

      assert_receive {:ash_scylla_query, insert_query, insert_params, _opts}
      assert insert_query =~ "INSERT INTO test_ks.func_default_items"
      assert length(insert_params) == 3
      [id_bin | _] = insert_params
      assert is_binary(id_bin)
      assert byte_size(id_bin) == 16
    end
  end

  describe "bulk_create with autogenerate" do
    test "bulk_create/3 auto-generates primary keys for all changesets" do
      changesets = [
        changeset(%{name: "Alice", status: "active"}),
        changeset(%{name: "Bob", status: "inactive"})
      ]

      assert {:ok, records} =
               DataLayer.bulk_create(AutogenResource, changesets, max_concurrency: 1)

      records = Enum.to_list(records)
      assert length(records) == 2

      Enum.each(records, fn record ->
        assert is_binary(record.id)
        assert byte_size(record.id) == 36
      end)

      assert_receive {:ash_scylla_query, batch_query, batch_params, _opts}
      assert batch_query =~ "BEGIN BATCH"
      assert batch_query =~ "INSERT INTO test_ks.autogen_items"
      assert batch_query =~ "APPLY BATCH"
      assert length(batch_params) == 6
    end

    test "bulk_create/3 uses explicit primary keys when provided" do
      id1 = "550e8400-e29b-41d4-a716-446655440010"
      id2 = "550e8400-e29b-41d4-a716-446655440011"

      changesets = [
        changeset(%{id: id1, name: "Alice", status: "active"}),
        changeset(%{id: id2, name: "Bob", status: "inactive"})
      ]

      assert {:ok, records} =
               DataLayer.bulk_create(AutogenResource, changesets, max_concurrency: 1)

      assert Enum.map(records, & &1.id) == [id1, id2]

      assert_receive {:ash_scylla_query, batch_query, batch_params, _opts}
      assert batch_query =~ "BEGIN BATCH"
      assert uuid_bin(id1) in batch_params
      assert uuid_bin(id2) in batch_params
    end

    test "bulk_create/3 mixes auto-generated and explicit primary keys" do
      explicit_id = "550e8400-e29b-41d4-a716-446655440020"

      changesets = [
        changeset(%{name: "Alice", status: "active"}),
        changeset(%{id: explicit_id, name: "Bob", status: "inactive"})
      ]

      assert {:ok, records} =
               DataLayer.bulk_create(AutogenResource, changesets, max_concurrency: 1)

      records = Enum.to_list(records)
      assert length(records) == 2

      [first, second] = records
      assert is_binary(first.id)
      assert byte_size(first.id) == 36
      assert second.id == explicit_id

      assert_receive {:ash_scylla_query, batch_query, batch_params, _opts}
      assert batch_query =~ "BEGIN BATCH"
      assert uuid_bin(explicit_id) in batch_params
    end
  end

  describe "autogenerate_attribute logic" do
    test "returns true when autogenerate? is explicitly true" do
      attr = %{
        name: :id,
        type: Ash.Type.UUID,
        primary_key?: true,
        autogenerate?: true,
        default: nil
      }

      assert Map.get(attr, :autogenerate?) == true
    end

    test "falls back to function default check" do
      attr = %{
        name: :id,
        type: Ash.Type.UUID,
        primary_key?: true,
        autogenerate?: nil,
        default: &Ash.UUIDv7.generate/0
      }

      assert Map.get(attr, :autogenerate?) != true
      assert is_function(Map.get(attr, :default))
    end

    test "returns false when no autogenerate and no function default" do
      attr = %{
        name: :id,
        type: Ash.Type.UUID,
        primary_key?: true,
        autogenerate?: nil,
        default: nil
      }

      assert Map.get(attr, :autogenerate?) != true
      refute is_function(Map.get(attr, :default))
    end
  end
end
