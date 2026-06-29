defmodule AshScylla.DataLayer.CrudTest do
  @moduledoc """
  Unit tests for the DataLayer CRUD/query execution surface using a fake repo.
  Verifies query generation, option passing, error wrapping, and result mapping.
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer
  alias AshScylla.Error.ScyllaError

  import AshScylla.DataLayer.Types, only: [uuid_string_to_binary: 1]

  defp uuid_bin(id), do: elem(uuid_string_to_binary(id), 1)

  # ---------------------------------------------------------------------------
  # Fake repo – pattern-matches on the exact CQL strings the DataLayer emits
  # ---------------------------------------------------------------------------

  defmodule FakeRepo do
    @moduledoc false

    # Unwraps {type, value} tuples from typed_params, keeping raw values for assertions.
    defp unwrap_params(params) do
      Enum.map(params, fn
        {_type, value} -> value
        value -> value
      end)
    end

    # Simulates real Xandra behavior: returns positional rows + string column names.
    # Receives {type, value} tuples from the data layer's typed params and unwraps for testing.
    def query(query, params, opts \\ []) do
      raw_params = unwrap_params(params)
      send(self(), {:ash_scylla_query, query, raw_params, opts})

      id_bin = fn
        id when is_binary(id) and byte_size(id) == 36 ->
          elem(AshScylla.DataLayer.Types.uuid_string_to_binary(id), 1)

        id ->
          id
      end

      case query do
        # --- inserts ---
        "INSERT INTO test_ks.crud_items" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        "INSERT INTO test_ks.lwt_items" <> _ ->
          {:ok, %Xandra.Page{content: [[false]]}}

        "INSERT INTO test_ks.lwt_success_items" <> _ ->
          {:ok, %Xandra.Page{content: [[true]]}}

        # --- batch ---
        "BEGIN BATCH" <> _ ->
          {:ok, %Xandra.Void{}}

        # --- updates ---
        "UPDATE test_ks.crud_items SET" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        "UPDATE test_ks.lwt_items SET" <> _ ->
          {:ok, %Xandra.Page{content: []}}

        # --- deletes ---
        "DELETE FROM test_ks.crud_items WHERE id = ?" ->
          {:ok, %Xandra.Page{content: []}}

        "DELETE FROM test_ks.crud_items WHERE status = ?" ->
          {:ok, %Xandra.Page{content: []}}

        # --- selects (real Xandra format: positional rows + string column names) ---
        "SELECT * FROM test_ks.crud_items WHERE id = ? LIMIT 1" ->
          [id] = params

          if id == "bad-fetch" do
            {:error, %Xandra.ConnectionError{reason: :timeout, action: nil}}
          else
            # Real Xandra returns UUID as 16-byte binary + string column names
            {:ok,
             %Xandra.Page{
               content: [[id_bin.(id), "Ada", "active", 42]],
               columns: ["id", "name", "status", "age"]
             }}
          end

        "SELECT * FROM test_ks.lwt_items WHERE id = ? LIMIT 1" ->
          [id] = params

          {:ok,
           %Xandra.Page{
             content: [[id_bin.(id), "Grace", "inactive"]],
             columns: ["id", "name", "status"]
           }}

        "SELECT * FROM test_ks.crud_items WHERE status = ? LIMIT ?" ->
          {:ok,
           %Xandra.Page{
             content: [
               [
                 elem(
                   AshScylla.DataLayer.Types.uuid_string_to_binary(
                     "550e8400-e29b-41d4-a716-446655440000"
                   ),
                   1
                 ),
                 "Ada",
                 "active",
                 42
               ]
             ],
             columns: ["id", "name", "status", "age"]
           }}

        "SELECT COUNT(*) FROM test_ks.crud_items" <> _ ->
          {:ok, %Xandra.Page{content: [[2]]}}

        # --- fallback ---
        _ ->
          {:error, %Xandra.Error{reason: :overloaded, message: nil, warnings: []}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Test resources
  # ---------------------------------------------------------------------------

  defmodule DisplayCalculation do
    @moduledoc false
    def calculate([record], _opts), do: record.name
  end

  defmodule Resource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    ash_scylla do
      repo(FakeRepo)
      table("crud_items")
      keyspace("test_ks")
      consistency(:one)
      ttl(60)
      secondary_index(:status)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:status, :string)
      attribute(:age, :integer)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule LwtResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    ash_scylla do
      repo(FakeRepo)
      table("lwt_items")
      keyspace("test_ks")
      consistency(:one)
      ttl(120)
      lwt(true)
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

  defmodule LwtSuccessResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    ash_scylla do
      repo(FakeRepo)
      table("lwt_success_items")
      keyspace("test_ks")
      consistency(:one)
      ttl(120)
      lwt(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
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

  defp base_query do
    %DataLayer{
      resource: Resource,
      repo: FakeRepo,
      table: "test_ks.crud_items",
      filters: [],
      sorts: [],
      limit: nil,
      offset: nil,
      select: nil,
      tenant: nil,
      context: %{}
    }
  end

  # ===========================================================================
  # create/2
  # ===========================================================================

  describe "create/2" do
    test "inserts with generated PK, TTL, keyspace, and consistency; then fetches" do
      changeset = changeset(%{name: "Ada", status: "active", age: 42})

      assert {:ok, record} = DataLayer.create(Resource, changeset)
      assert record.name == "Ada"
      assert record.status == "active"
      assert record.age == 42
      record_id = record.id
      assert is_binary(record_id)

      # INSERT
      assert_receive {:ash_scylla_query, insert_query, insert_params, opts}
      assert insert_query =~ "INSERT INTO test_ks.crud_items"
      assert insert_query =~ "USING TTL 60"
      assert opts[:consistency] == :one
      assert Enum.sort(insert_params) == Enum.sort([uuid_bin(record_id), "Ada", 42, "active"])

      id_bin = uuid_bin(record_id)

      # fetch-by-PK (params are the 16-byte binary UUID)
      assert_receive {:ash_scylla_query, fetch_query, [^id_bin], []}
      assert fetch_query == "SELECT * FROM test_ks.crud_items WHERE id = ? LIMIT 1"
    end

    test "wraps fetch-by-primary-key connection errors" do
      changeset = changeset(%{id: "bad-fetch", name: "Ada"})

      assert {:error, error} = DataLayer.create(Resource, changeset)
      assert %ScyllaError{type: :connection_timeout} = error

      assert_receive {:ash_scylla_query, "SELECT * FROM test_ks.crud_items WHERE id = ? LIMIT 1",
                      ["bad-fetch"], []}
    end
  end

  # ===========================================================================
  # update/2
  # ===========================================================================

  describe "update/2" do
    test "updates by primary key and fetches the updated record" do
      id = generate_uuid()
      changeset = changeset(%{id: id, name: "Grace"})

      assert {:ok, record} = DataLayer.update(Resource, changeset)
      # Fake repo returns hardcoded data; just verify the record was fetched
      assert record.id == id
      assert record.name == "Ada"

      assert_receive {:ash_scylla_query, update_query, _update_params, opts}
      assert update_query =~ "UPDATE test_ks.crud_items SET"
      assert update_query =~ "WHERE id = ?"
      assert opts[:consistency] == :one

      id_bin = uuid_bin(id)

      assert_receive {:ash_scylla_query, "SELECT * FROM test_ks.crud_items WHERE id = ? LIMIT 1",
                      [^id_bin], []}
    end
  end

  # ===========================================================================
  # destroy/2
  # ===========================================================================

  describe "destroy/2" do
    test "deletes by primary key" do
      id = generate_uuid()

      id_bin = uuid_bin(id)

      assert :ok = DataLayer.destroy(Resource, changeset(%{id: id}))

      assert_receive {:ash_scylla_query, delete_query, [^id_bin], opts}
      assert delete_query == "DELETE FROM test_ks.crud_items WHERE id = ?"
      assert opts[:consistency] == :one
    end
  end

  # ===========================================================================
  # upsert/3
  # ===========================================================================

  describe "upsert/3" do
    test "performs a non-LWT upsert with TTL" do
      id = generate_uuid()

      assert {:ok, record} = DataLayer.upsert(Resource, changeset(%{id: id, name: "Upsert"}))
      assert record.name == "Upsert"

      id_bin = uuid_bin(id)

      assert_receive {:ash_scylla_query, upsert_query, [^id_bin, "Upsert"], opts}
      assert upsert_query =~ "INSERT INTO test_ks.crud_items"
      assert upsert_query =~ "USING TTL 60"
      refute upsert_query =~ "IF NOT EXISTS"
      assert opts[:consistency] == :one
    end

    test "falls back to update when LWT insert reports a conflict" do
      id = generate_uuid()

      assert {:ok, record} = DataLayer.upsert(LwtResource, changeset(%{id: id, name: "Grace"}))
      assert record.name == "Grace"

      id_bin = uuid_bin(id)

      # LWT insert returns [[false]] → conflict → falls back to update
      assert_receive {:ash_scylla_query, upsert_query, [^id_bin, "Grace"], opts}
      assert upsert_query =~ "INSERT INTO test_ks.lwt_items"
      assert upsert_query =~ "IF NOT EXISTS"
      assert opts[:consistency] == :one

      assert_receive {:ash_scylla_query, update_query, _update_params, _opts}
      assert update_query =~ "UPDATE test_ks.lwt_items SET"
      assert update_query =~ "WHERE id = ?"

      assert_receive {:ash_scylla_query, "SELECT * FROM test_ks.lwt_items WHERE id = ? LIMIT 1",
                      [^id_bin], []}
    end

    test "returns the record when LWT insert succeeds" do
      id = generate_uuid()

      assert {:ok, record} =
               DataLayer.upsert(LwtSuccessResource, changeset(%{id: id, name: "LWT"}))

      assert record.name == "LWT"

      id_bin = uuid_bin(id)

      assert_receive {:ash_scylla_query, upsert_query, [^id_bin, "LWT"], opts}
      assert upsert_query =~ "INSERT INTO test_ks.lwt_success_items"
      assert upsert_query =~ "IF NOT EXISTS"
      assert opts[:consistency] == :one
    end
  end

  # ===========================================================================
  # bulk_create/3
  # ===========================================================================

  describe "bulk_create/3" do
    test "builds a batch insert and returns records from changeset attributes" do
      id1 = generate_uuid()
      id2 = generate_uuid()

      changesets = [
        changeset(%{id: id1, name: "Ada", status: "active"}),
        changeset(%{id: id2, name: "Grace", status: "inactive"})
      ]

      assert {:ok, records} = DataLayer.bulk_create(Resource, changesets, max_concurrency: 1)
      assert Enum.map(records, & &1.name) == ["Ada", "Grace"]

      assert_receive {:ash_scylla_query, batch_query, batch_params, opts}
      assert batch_query =~ "BEGIN BATCH"
      assert batch_query =~ "INSERT INTO test_ks.crud_items"
      assert batch_query =~ "APPLY BATCH"
      assert opts[:consistency] == :one

      assert Enum.sort(batch_params) ==
               Enum.sort([uuid_bin(id1), "Ada", "active", uuid_bin(id2), "Grace", "inactive"])
    end
  end

  # ===========================================================================
  # run_query/2
  # ===========================================================================

  describe "run_query/2" do
    test "executes an optimized query, maps rows, and applies expression calculations" do
      query = %{
        base_query()
        | filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
          limit: 10,
          context: %{
            calculations: [
              %{name: :display_name, expr: fn record -> record.name <> "!" end}
            ]
          }
      }

      assert {:ok, [record]} = DataLayer.run_query(query, Resource)
      assert record.name == "Ada"
      assert record.display_name == "Ada!"

      assert_receive {:ash_scylla_query, select_query, ["active", 10], opts}
      assert select_query == "SELECT * FROM test_ks.crud_items WHERE status = ? LIMIT ?"
      assert opts[:consistency] == :one
    end

    test "applies module-backed calculations" do
      query = %{
        base_query()
        | filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
          limit: 10,
          context: %{
            calculations: [
              %{name: :module_name, module: DisplayCalculation, opts: []}
            ]
          }
      }

      assert {:ok, [record]} = DataLayer.run_query(query, Resource)
      assert record.module_name == "Ada"
    end

    test "ignores unsupported calculations" do
      query = %{
        base_query()
        | filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
          limit: 10,
          context: %{
            calculations: [
              %{name: :ignored}
            ]
          }
      }

      assert {:ok, [record]} = DataLayer.run_query(query, Resource)
      refute Map.has_key?(record, :ignored)
    end

    test "wraps query errors" do
      query = %{base_query() | table: "missing_table"}

      assert {:error, error} = DataLayer.run_query(query, Resource)
      assert %ScyllaError{type: :overloaded} = error
    end
  end

  # ===========================================================================
  # update_query/4 and destroy_query/4
  # ===========================================================================

  describe "update_query/4 and destroy_query/4" do
    test "bulk updates by filter then re-runs the read query with original filters" do
      query = %{
        base_query()
        | filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
          limit: 10
      }

      assert {:ok, [record]} =
               DataLayer.update_query(query, changeset(%{status: "inactive"}), Resource, [])

      assert record.name == "Ada"

      assert_receive {:ash_scylla_query, _update_query, _update_params, opts}
      assert opts[:consistency] == :one

      # update_query re-runs the original query (with original filters) to fetch results
      assert_receive {:ash_scylla_query, select_query, ["active", 10], _opts}
      assert select_query == "SELECT * FROM test_ks.crud_items WHERE status = ? LIMIT ?"
    end

    test "bulk deletes by filter" do
      query = %{
        base_query()
        | filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}]
      }

      assert DataLayer.destroy_query(query, changeset(%{}), [], Resource) == :ok

      assert_receive {:ash_scylla_query, delete_query, ["active"], opts}
      assert delete_query == "DELETE FROM test_ks.crud_items WHERE status = ?"
      assert opts[:consistency] == :one
    end
  end

  # ===========================================================================
  # run_aggregate_query/3
  # ===========================================================================

  describe "run_aggregate_query/3" do
    test "runs COUNT aggregates and returns named counts" do
      query = %{
        base_query()
        | filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}]
      }

      assert {:ok, %{total: 2}} =
               DataLayer.run_aggregate_query(query, [%{kind: :count, name: :total}], Resource)

      assert_receive {:ash_scylla_query, aggregate_query, ["active"], opts}
      assert aggregate_query == "SELECT COUNT(*) FROM test_ks.crud_items WHERE status = ?"
      assert opts[:consistency] == :one
    end

    test "returns an error for unsupported aggregate kinds" do
      query = base_query()

      assert {:error, error} =
               DataLayer.run_aggregate_query(query, [%{kind: :sum, name: :total}], Resource)

      assert %ScyllaError{} = error
      # The error message comes from ScyllaError.from_error which wraps the string
      assert error.message =~ "Aggregate kind sum"
    end
  end

  # ===========================================================================
  # distinct/3
  # ===========================================================================

  describe "distinct/3" do
    test "stores partition-key distinct columns in select" do
      assert {:ok, query} = DataLayer.distinct(base_query(), [:id], Resource)
      assert query.select == [:id]
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    "#{format_hex(a, 8)}-#{format_hex(b, 4)}-#{format_hex(c, 4)}-#{format_hex(d, 4)}-#{format_hex(e, 12)}"
  end

  defp format_hex(value, len) do
    value |> Integer.to_string(16) |> String.pad_leading(len, "0")
  end
end
