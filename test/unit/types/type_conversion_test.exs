defmodule AshScylla.TypeConversionTest do
  @moduledoc """
  Tests for type conversion between Ash and ScyllaDB types.

  Verifies:
  1. The `Connection.type_value/1` encoding function maps Elixir values to correct CQL types
  2. Full round-trip: encode → write to ScyllaDB (via FakeRepo) → decode → verify types match
  3. CQL type mapping (AshScylla.DataLayer.Types)
  """

  use ExUnit.Case, async: true
  @moduletag :integration

  alias AshScylla.Connection
  alias AshScylla.DataLayer

  # ============================================================================
  # 1. Connection.type_value/1 — write-path encoding
  # ============================================================================

  describe "Connection.type_value/1 — write-path encoding" do
    test "encodes string as text" do
      assert Connection.typed_params(["hello"]) == [{"text", "hello"}]
    end

    test "encodes integer as bigint" do
      assert Connection.typed_params([42]) == [{"bigint", 42}]
    end

    test "encodes float as double" do
      assert Connection.typed_params([3.14]) == [{"double", 3.14}]
    end

    test "encodes true as boolean" do
      assert Connection.typed_params([true]) == [{"boolean", true}]
    end

    test "encodes false as boolean" do
      assert Connection.typed_params([false]) == [{"boolean", false}]
    end

    test "encodes nil as nil" do
      assert Connection.typed_params([nil]) == [nil]
    end

    test "encodes list as list" do
      assert Connection.typed_params([[1, 2, 3]]) == [{"list", [1, 2, 3]}]
    end

    test "encodes map as map" do
      assert Connection.typed_params([%{key: "value"}]) == [{"map", %{key: "value"}}]
    end

    test "encodes Date as date struct" do
      date = ~D[2024-01-15]
      assert Connection.typed_params([date]) == [{"date", date}]
    end

    test "encodes Time as time struct" do
      time = ~T[14:30:00]
      assert Connection.typed_params([time]) == [{"time", time}]
    end

    test "encodes DateTime as timestamp struct" do
      dt = ~U[2024-01-15 10:30:00Z]
      assert Connection.typed_params([dt]) == [{"timestamp", dt}]
    end

    test "already-typed tuples pass through unchanged" do
      uuid = {"uuid", "550e8400-e29b-41d4-a716-446655440000"}
      assert Connection.typed_params([uuid]) == [uuid]
    end

    test "encodes unknown values as text" do
      assert Connection.typed_params([:some_atom]) == [{"text", "some_atom"}]
    end

    test "encodes integer boundaries" do
      assert Connection.typed_params([0]) == [{"bigint", 0}]
      assert Connection.typed_params([-1]) == [{"bigint", -1}]

      assert Connection.typed_params([9_007_199_254_740_991]) == [
               {"bigint", 9_007_199_254_740_991}
             ]

      assert Connection.typed_params([-9_007_199_254_740_991]) == [
               {"bigint", -9_007_199_254_740_991}
             ]
    end

    test "encodes empty list and map" do
      assert Connection.typed_params([[]]) == [{"list", []}]
      assert Connection.typed_params([%{}]) == [{"map", %{}}]
    end

    test "encodes nested structures" do
      nested = %{"key" => [1, 2, 3]}
      assert Connection.typed_params([nested]) == [{"map", nested}]
    end

    test "encodes Decimal struct" do
      decimal = Decimal.new("123.45")
      assert Connection.typed_params([decimal]) == [{"decimal", decimal}]
    end
  end

  # ============================================================================
  # 2. Full round-trip: encode → write → read back → verify types
  # ============================================================================

  describe "full round-trip via DataLayer CRUD" do
    defmodule FakeTypeRepo do
      @moduledoc false

      def query(query, params, opts \\ []) do
        send(self(), {:type_query, query, params, opts})

        cond do
          String.starts_with?(query, "INSERT INTO type_roundtrip") ->
            {:ok, %Xandra.Page{content: []}}

          String.contains?(query, "SELECT * FROM type_roundtrip WHERE id = ?") ->
            [id] = params

            row =
              case id do
                "roundtrip-id-1" ->
                  %{
                    id: "roundtrip-id-1",
                    name: "Round Trip",
                    age: 25,
                    score: 4.5,
                    rating: 8.75,
                    is_active: true,
                    bio: "Testing type round-trip",
                    count: 1000,
                    small_val: 127,
                    tiny_val: 99,
                    ip_address: "192.168.1.1",
                    birth_date: ~D[2000-01-01],
                    lunch_time: ~T[12:00:00],
                    last_login: ~U[2024-06-15 08:30:00Z],
                    settings: %{"language" => "elixir"},
                    tags: ["test", "types"],
                    metadata_blob: <<0, 255, 128>>
                  }

                "boundary-id" ->
                  %{
                    id: "boundary-id",
                    name: "Boundaries",
                    age: 9_007_199_254_740_991,
                    small_val: 32_767,
                    tiny_val: 255,
                    score: 1.0,
                    rating: 1.0,
                    is_active: true,
                    birth_date: ~D[2024-01-01],
                    lunch_time: ~T[00:00:00],
                    last_login: ~U[2024-01-01 00:00:00Z],
                    settings: nil,
                    tags: nil,
                    metadata_blob: nil
                  }

                "empty-col-id" ->
                  %{
                    id: "empty-col-id",
                    name: "Empty",
                    age: nil,
                    score: nil,
                    rating: nil,
                    is_active: nil,
                    bio: nil,
                    count: nil,
                    small_val: nil,
                    tiny_val: nil,
                    ip_address: nil,
                    birth_date: nil,
                    lunch_time: nil,
                    last_login: nil,
                    settings: %{},
                    tags: [],
                    metadata_blob: <<>>
                  }

                "update-type-id" ->
                  %{
                    id: "update-type-id",
                    name: "Updated",
                    age: 35,
                    score: 9.99,
                    rating: 1.0,
                    is_active: true,
                    bio: nil,
                    count: nil,
                    small_val: nil,
                    tiny_val: nil,
                    ip_address: nil,
                    birth_date: ~D[1995-12-25],
                    lunch_time: nil,
                    last_login: ~U[2024-12-01 00:00:00Z],
                    settings: %{"theme" => "light"},
                    tags: ["updated"],
                    metadata_blob: nil
                  }

                "nil-fields-id" ->
                  %{
                    id: "nil-fields-id",
                    name: "Nullable",
                    age: nil,
                    score: nil,
                    rating: nil,
                    is_active: nil,
                    bio: nil,
                    count: nil,
                    small_val: nil,
                    tiny_val: nil,
                    ip_address: nil,
                    birth_date: nil,
                    lunch_time: nil,
                    last_login: nil,
                    settings: nil,
                    tags: nil,
                    metadata_blob: nil
                  }

                _ ->
                  %{
                    id: id,
                    name: "Generic",
                    age: 0,
                    score: 0.0,
                    rating: 0.0,
                    is_active: false,
                    bio: "",
                    count: 0,
                    small_val: 0,
                    tiny_val: 0,
                    ip_address: nil,
                    birth_date: nil,
                    lunch_time: nil,
                    last_login: nil,
                    settings: nil,
                    tags: nil,
                    metadata_blob: nil
                  }
              end

            {:ok, %Xandra.Page{content: [row]}}

          String.starts_with?(query, "UPDATE type_roundtrip") ->
            {:ok, %Xandra.Page{content: []}}

          String.starts_with?(query, "DELETE FROM type_roundtrip") ->
            {:ok, %Xandra.Page{content: []}}

          String.contains?(query, "SELECT") and String.contains?(query, "WHERE") ->
            {:ok, %Xandra.Page{content: [%{id: "filtered", name: "Filtered"}]}}

          true ->
            {:error, %Xandra.Error{reason: :overloaded, message: nil, warnings: []}}
        end
      end
    end

    defmodule RoundTripResource do
      @moduledoc false

      use Ash.Resource,
        domain: nil,
        data_layer: AshScylla.DataLayer

      import AshScylla.DataLayer.Dsl

      ash_scylla do
        repo(FakeTypeRepo)
        table("type_roundtrip")
        keyspace("test_ks")
        consistency(:one)
        ttl(3600)
      end

      attributes do
        uuid_primary_key(:id)

        attribute :name, :string do
          allow_nil?(false)
        end

        attribute(:age, :integer)
        attribute(:score, :float)
        attribute(:rating, :float)
        attribute(:is_active, :boolean)
        attribute(:bio, :string)
        attribute(:count, :integer)
        attribute(:small_val, :integer)
        attribute(:tiny_val, :integer)
        attribute(:ip_address, :string)
        attribute(:birth_date, :date)
        attribute(:lunch_time, :time)
        attribute(:last_login, :utc_datetime)

        attribute :settings, :map do
          default(%{})
        end

        attribute :tags, {:array, :string} do
          default([])
        end

        attribute(:metadata_blob, :binary)
      end

      actions do
        defaults([:create, :read, :update, :destroy])
      end
    end

    setup do
      receive do
        {:type_query, _, _, _} -> flush_messages()
      after
        0 -> :ok
      end

      :ok
    end

    defp flush_messages do
      receive do
        {:type_query, _, _, _} -> flush_messages()
      after
        0 -> :ok
      end
    end

    defp changeset(attrs), do: %Ash.Changeset{attributes: attrs}

    test "create/2 inserts and fetches a record with all Scylla type variants" do
      id = "roundtrip-id-1"

      attrs = %{
        id: id,
        name: "Round Trip",
        age: 25,
        score: 4.5,
        rating: 8.75,
        is_active: true,
        bio: "Testing type round-trip",
        count: 1000,
        small_val: 127,
        tiny_val: 99,
        ip_address: "192.168.1.1",
        birth_date: ~D[2000-01-01],
        lunch_time: ~T[12:00:00],
        last_login: ~U[2024-06-15 08:30:00Z],
        settings: %{"language" => "elixir"},
        tags: ["test", "types"],
        metadata_blob: <<0, 255, 128>>
      }

      assert {:ok, record} = DataLayer.create(RoundTripResource, changeset(attrs))

      # string/ID
      assert record.id == id
      assert is_binary(record.id)

      # string → TEXT
      assert record.name == "Round Trip"
      assert is_binary(record.name)

      # integer → BIGINT
      assert record.age == 25
      assert is_integer(record.age)

      # float → FLOAT
      assert record.score == 4.5
      assert is_float(record.score)

      # float → FLOAT
      assert record.rating == 8.75
      assert is_float(record.rating)

      # boolean
      assert record.is_active == true
      assert is_boolean(record.is_active)

      # string (TEXT)
      assert record.bio == "Testing type round-trip"
      assert is_binary(record.bio)

      # integer (BIGINT)
      assert record.count == 1000
      assert is_integer(record.count)

      # smallint (stored as integer)
      assert record.small_val == 127
      assert is_integer(record.small_val)

      # tinyint (stored as integer)
      assert record.tiny_val == 99
      assert is_integer(record.tiny_val)

      # inet (stored as string)
      assert record.ip_address == "192.168.1.1"
      assert is_binary(record.ip_address)

      # date
      assert record.birth_date == ~D[2000-01-01]
      assert %Date{} = record.birth_date

      # time
      assert record.lunch_time == ~T[12:00:00]
      assert %Time{} = record.lunch_time

      # utc_datetime / timestamp
      assert record.last_login == ~U[2024-06-15 08:30:00Z]
      assert %DateTime{} = record.last_login

      # map → MAP<TEXT, TEXT>
      assert record.settings == %{"language" => "elixir"}
      assert is_map(record.settings)

      # array → LIST<TEXT>
      assert record.tags == ["test", "types"]
      assert is_list(record.tags)

      # binary → BLOB
      assert record.metadata_blob == <<0, 255, 128>>
      assert is_binary(record.metadata_blob)

      # Verify the INSERT CQL was built with all the params
      assert_receive {:type_query, insert_query, insert_params, _opts}
      assert insert_query =~ "INSERT INTO type_roundtrip"
      assert id in insert_params
      assert "Round Trip" in insert_params
    end

    test "create/2 preserves types for boundary values" do
      id = "boundary-id"

      attrs = %{
        id: id,
        name: "Boundaries",
        age: 9_007_199_254_740_991,
        small_val: 32_767,
        tiny_val: 255,
        score: 1.0,
        rating: 1.0,
        is_active: true,
        birth_date: ~D[2024-01-01],
        lunch_time: ~T[00:00:00],
        last_login: ~U[2024-01-01 00:00:00Z]
      }

      assert {:ok, record} = DataLayer.create(RoundTripResource, changeset(attrs))

      assert record.age == 9_007_199_254_740_991
      assert record.small_val == 32_767
      assert record.tiny_val == 255
      assert is_boolean(record.is_active)
      assert %Date{} = record.birth_date
      assert %Time{} = record.lunch_time
      assert %DateTime{} = record.last_login
    end

    test "create/2 with empty collections preserves types" do
      id = "empty-col-id"

      attrs = %{
        id: id,
        name: "Empty",
        settings: %{},
        tags: [],
        metadata_blob: <<>>
      }

      assert {:ok, record} = DataLayer.create(RoundTripResource, changeset(attrs))

      assert record.settings == %{}
      assert is_map(record.settings)

      assert record.tags == []
      assert is_list(record.tags)

      assert record.metadata_blob == <<>>
      assert is_binary(record.metadata_blob)
    end

    test "create/2 with nil fields preserves nil across round-trip" do
      id = "nil-fields-id"

      attrs = %{
        id: id,
        name: "Nullable",
        age: nil,
        score: nil,
        rating: nil,
        is_active: nil,
        bio: nil,
        count: nil,
        small_val: nil,
        tiny_val: nil,
        ip_address: nil,
        birth_date: nil,
        lunch_time: nil,
        last_login: nil,
        settings: nil,
        tags: nil,
        metadata_blob: nil
      }

      assert {:ok, record} = DataLayer.create(RoundTripResource, changeset(attrs))

      assert record.id == id
      assert record.name == "Nullable"
      assert record.age == nil
      assert record.score == nil
      assert record.rating == nil
      assert record.is_active == nil
      assert record.bio == nil
      assert record.count == nil
      assert record.small_val == nil
      assert record.tiny_val == nil
      assert record.ip_address == nil
      assert record.birth_date == nil
      assert record.lunch_time == nil
      assert record.last_login == nil
      assert record.settings == nil
      assert record.tags == nil
      assert record.metadata_blob == nil
    end

    test "update/2 preserves types when updating fields" do
      id = "update-type-id"

      # Create
      attrs = %{
        id: id,
        name: "Original",
        age: 20,
        score: 1.5,
        is_active: false,
        birth_date: ~D[2000-06-15]
      }

      assert {:ok, _created} = DataLayer.create(RoundTripResource, changeset(attrs))
      assert_receive {:type_query, _, _, _}

      # Update with new values
      update_attrs = %{
        name: "Updated",
        age: 35,
        score: 9.99,
        is_active: true,
        birth_date: ~D[1995-12-25],
        last_login: ~U[2024-12-01 00:00:00Z],
        settings: %{"theme" => "light"},
        tags: ["updated"]
      }

      assert {:ok, record} =
               DataLayer.update(
                 RoundTripResource,
                 changeset(Map.merge(attrs, update_attrs))
               )

      assert record.name == "Updated"
      assert record.age == 35
      assert is_integer(record.age)
      assert record.score == 9.99
      assert is_float(record.score)
      assert record.is_active == true
      assert is_boolean(record.is_active)
      assert record.birth_date == ~D[1995-12-25]
      assert %Date{} = record.birth_date
      assert record.last_login == ~U[2024-12-01 00:00:00Z]
      assert %DateTime{} = record.last_login
      assert record.settings == %{"theme" => "light"}
      assert is_map(record.settings)
      assert record.tags == ["updated"]
      assert is_list(record.tags)
    end
  end

  # ============================================================================
  # 3. CQL type mapping verification
  # ============================================================================

  describe "AshScylla.DataLayer.Types — type mapping" do
    alias AshScylla.DataLayer.Types

    test "cql_type/1 maps Ash types to CQL types correctly" do
      assert Types.cql_type(:text) == "TEXT"
      assert Types.cql_type(:int) == "INT"
      assert Types.cql_type(:bigint) == "BIGINT"
      assert Types.cql_type(:boolean) == "BOOLEAN"
      assert Types.cql_type(:uuid) == "UUID"
      assert Types.cql_type(:timestamp) == "TIMESTAMP"
      assert Types.cql_type(:float) == "DOUBLE"
      assert Types.cql_type(:double) == "DOUBLE"
      assert Types.cql_type(:blob) == "BLOB"
      assert Types.cql_type(:inet) == "INET"
      assert Types.cql_type(:date) == "DATE"
      assert Types.cql_type(:time) == "TIME"
      assert Types.cql_type(:smallint) == "SMALLINT"
      assert Types.cql_type(:tinyint) == "TINYINT"
      assert Types.cql_type(:duration) == "DURATION"
    end

    test "cql_type/1 maps Ash DSL aliases to CQL types" do
      assert Types.cql_type(:string) == "TEXT"
      assert Types.cql_type(:integer) == "BIGINT"
      assert Types.cql_type(:utc_datetime) == "TIMESTAMP"
      assert Types.cql_type(:utc_datetime_usec) == "TIMESTAMP"
      assert Types.cql_type(:naive_datetime) == "TIMESTAMP"
      assert Types.cql_type(:naive_datetime_usec) == "TIMESTAMP"
      assert Types.cql_type(:decimal) == "DECIMAL"
      assert Types.cql_type(:binary) == "BLOB"
    end

    test "ash_type_to_cql_type/2 resolves Ash type modules to CQL types" do
      assert Types.ash_type_to_cql_type(Ash.Type.UUID, []) == "UUID"
      assert Types.ash_type_to_cql_type(Ash.Type.String, []) == "TEXT"
      assert Types.ash_type_to_cql_type(Ash.Type.Integer, []) == "BIGINT"
      assert Types.ash_type_to_cql_type(Ash.Type.Float, []) == "DOUBLE"
      assert Types.ash_type_to_cql_type(Ash.Type.Boolean, []) == "BOOLEAN"
      assert Types.ash_type_to_cql_type(Ash.Type.Date, []) == "DATE"
      assert Types.ash_type_to_cql_type(Ash.Type.Time, []) == "TIME"
      assert Types.ash_type_to_cql_type(Ash.Type.UtcDatetime, []) == "TIMESTAMP"
      assert Types.ash_type_to_cql_type(Ash.Type.UtcDatetimeUsec, []) == "TIMESTAMP"
      assert Types.ash_type_to_cql_type(Ash.Type.NaiveDatetime, []) == "TIMESTAMP"
      assert Types.ash_type_to_cql_type(Ash.Type.Decimal, []) == "DECIMAL"
      assert Types.ash_type_to_cql_type(Ash.Type.Binary, []) == "BLOB"
      assert Types.ash_type_to_cql_type(Ash.Type.Atom, []) == "TEXT"
      assert Types.ash_type_to_cql_type(Ash.Type.Duration, []) == "DURATION"
    end

    test "ash_type_to_cql_type/2 resolves tuple types" do
      assert Types.ash_type_to_cql_type({:array, Ash.Type.String}, []) == "LIST<TEXT>"
      assert Types.ash_type_to_cql_type({:array, Ash.Type.Integer}, []) == "LIST<BIGINT>"
      assert Types.ash_type_to_cql_type({:set, Ash.Type.String}, []) == "SET<TEXT>"

      assert Types.ash_type_to_cql_type({:map, Ash.Type.String, Ash.Type.Integer}, []) ==
               "MAP<TEXT, BIGINT>"

      assert Types.ash_type_to_cql_type({:map, Ash.Type.UUID, Ash.Type.Float}, []) ==
               "MAP<UUID, DOUBLE>"
    end

    test "resolve_type/1 passes plain atoms through unchanged" do
      assert Types.ash_type_to_cql_type(:uuid, []) == "UUID"
      assert Types.ash_type_to_cql_type(:string, []) == "TEXT"
      assert Types.ash_type_to_cql_type(:custom_type, []) == "TEXT"
    end

    test "resolve_type/1 handles unknown Ash type module" do
      assert Types.ash_type_to_cql_type(SomeMadeUp.Module, []) == "TEXT"
    end

    test "cql_type/1 falls back to TEXT for unknown types" do
      assert Types.cql_type(:custom_type) == "TEXT"
      assert Types.cql_type(:unknown) == "TEXT"
    end

    test "ash_type_to_cql_type/2 handles composite types" do
      assert Types.ash_type_to_cql_type(:map, key_type: "TEXT", value_type: "INT") ==
               "MAP<TEXT, INT>"

      assert Types.ash_type_to_cql_type(:array, element_type: "UUID") == "LIST<UUID>"
      assert Types.ash_type_to_cql_type(:set, element_type: "TEXT") == "SET<TEXT>"
      assert Types.ash_type_to_cql_type(:udt, type_name: "my_type") == "frozen<my_type>"
    end

    test "ash_type_to_cql_type/2 with :frozen option wraps in frozen<>" do
      assert Types.ash_type_to_cql_type(:string, frozen: true) == "frozen<TEXT>"
      assert Types.ash_type_to_cql_type(:uuid, frozen: true) == "frozen<UUID>"
    end
  end

  # ============================================================================
  # 4. Verify Ash → Scylla type consistency
  # ============================================================================

  describe "Ash → Scylla type consistency" do
    alias AshScylla.DataLayer.Types

    @ash_scylla_type_pairs %{
      string: "TEXT",
      integer: "BIGINT",
      float: "DOUBLE",
      boolean: "BOOLEAN",
      uuid: "UUID",
      utc_datetime: "TIMESTAMP",
      date: "DATE",
      time: "TIME",
      binary: "BLOB"
    }

    test "all Ash types have a corresponding CQL type mapping" do
      Enum.each(@ash_scylla_type_pairs, fn {ash_type, expected_cql} ->
        actual = Types.cql_type(ash_type)

        assert actual == expected_cql,
               "Expected #{ash_type} → #{expected_cql}, got #{actual}"
      end)
    end

    test "all Ash type modules resolve to corresponding CQL type mappings" do
      Enum.each(@ash_scylla_type_pairs, fn {ash_type, expected_cql} ->
        short_names = Ash.Type.Registry.short_names()
        {^ash_type, type_module} = List.keyfind(short_names, ash_type, 0)
        actual = Types.ash_type_to_cql_type(type_module, [])

        assert actual == expected_cql,
               "Expected #{inspect(type_module)} → #{expected_cql}, got #{actual}"
      end)
    end

    test "Connection.type_value/1 type assignments match CQL column definitions" do
      # string → TEXT → {"text", value}
      assert {"text", "hello"} |> elem(0) == "text"

      # integer → BIGINT → {"bigint", value}
      assert {"bigint", 42} |> elem(0) == "bigint"

      # float → FLOAT → {"float", value}
      # Note: Connection.type_value/1 encodes Elixir floats as "double"
      # since ScyllaDB uses DOUBLE as the default floating-point type
      assert {"double", 3.14} |> elem(0) == "double"

      # boolean → BOOLEAN → {"boolean", value}
      assert {"boolean", true} |> elem(0) == "boolean"

      # DateTime → TIMESTAMP → {"timestamp", value}
      assert {"timestamp", ~U[2024-01-01 00:00:00Z]} |> elem(0) == "timestamp"

      # Date → DATE → {"date", value}
      assert {"date", ~D[2024-01-01]} |> elem(0) == "date"

      # Time → TIME → {"time", value}
      assert {"time", ~T[12:00:00]} |> elem(0) == "time"
    end
  end
end
