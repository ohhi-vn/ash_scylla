defmodule AshScylla.DataLayer.TypesCoverageTest do
  @moduledoc """
  Coverage for the remaining branches of `AshScylla.DataLayer.Types`: the
  canonical mapping accessor, unknown-type fallbacks, frozen wrappers, and
  Ash type-module resolution.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Types

  defmodule CustomTypeModule do
    @moduledoc false
    # A module type without storage_type/1 that is absent from the registry,
    # exercising the registry-miss fallback.
  end

  describe "cql_type_mapping/0" do
    test "exposes the canonical atom → CQL mapping" do
      mapping = Types.cql_type_mapping()

      assert is_map(mapping)
      assert mapping[:text] == "TEXT"
      assert mapping[:int] == "INT"
      assert mapping[:bigint] == "BIGINT"
      assert mapping[:uuid] == "UUID"
      assert mapping[:inet] == "INET"
      assert mapping[:smallint] == "SMALLINT"
      assert mapping[:tinyint] == "TINYINT"
      assert mapping[:duration] == "DURATION"
      assert mapping[:naive_datetime_usec] == "TIMESTAMP"
    end
  end

  describe "cql_type/1 fallbacks" do
    test "unknown atoms fall back to TEXT" do
      assert Types.cql_type(:not_a_known_type) == "TEXT"
    end

    test "field and element helpers delegate to cql_type" do
      assert Types.field_type_to_cql(:blob) == "BLOB"
      assert Types.cql_element_type(:double) == "DOUBLE"
      assert Types.cql_element_type(:whatever) == "TEXT"
    end
  end

  describe "ash_type_to_cql_type/2 resolution branches" do
    test "Ash.Type.Float maps to DOUBLE while :float stays DOUBLE-compatible" do
      assert Types.ash_type_to_cql_type(Ash.Type.Float, []) == "DOUBLE"
      assert Types.ash_type_to_cql_type(:float, []) == "DOUBLE"
    end

    test "map/array/set accept element options" do
      assert Types.ash_type_to_cql_type(:map, key_type: "UUID", value_type: "INT") ==
               "MAP<UUID, INT>"

      assert Types.ash_type_to_cql_type(:array, element_type: "UUID") == "LIST<UUID>"
      assert Types.ash_type_to_cql_type(:set, element_type: "BIGINT") == "SET<BIGINT>"
    end

    test ":udt renders frozen with the configured or default name" do
      assert Types.ash_type_to_cql_type(:udt, type_name: :my_udt) == "frozen<my_udt>"
      assert Types.ash_type_to_cql_type(:udt, []) == "frozen<undefined>"
    end

    test "frozen option wraps any base type" do
      assert Types.ash_type_to_cql_type(:uuid, frozen: true) == "frozen<UUID>"
      # The frozen option applies to the innermost element for tuple forms.
      assert Types.ash_type_to_cql_type({:array, :uuid}, frozen: true) ==
               "LIST<frozen<UUID>>"
    end

    test "tuple types compose inner elements" do
      assert Types.ash_type_to_cql_type({:tuple, [:text, :int]}, []) == "TUPLE<TEXT, INT>"
    end

    test "nested tuple collections recurse" do
      assert Types.ash_type_to_cql_type({:array, {:set, :uuid}}, []) == "LIST<SET<UUID>>"

      assert Types.ash_type_to_cql_type({:map, :string, {:array, :uuid}}, []) ==
               "MAP<TEXT, LIST<UUID>>"
    end

    test "module types resolve through storage_type when available" do
      assert Types.ash_type_to_cql_type(Ash.Type.CiString, []) == "TEXT"
      assert Types.ash_type_to_cql_type(Ash.Type.UUID, []) == "UUID"
    end

    test "unregistered module types fall back to TEXT without crashing" do
      assert Types.ash_type_to_cql_type(CustomTypeModule, []) == "TEXT"
    end

    test "unknown terms fall back to TEXT" do
      assert Types.ash_type_to_cql_type({:something, :else}, []) == "TEXT"
    end
  end

  describe "value conversion helpers" do
    test "uuid string ⇄ binary round-trips" do
      uuid = Ash.UUID.generate()
      {:ok, bin} = Types.uuid_string_to_binary(uuid)

      assert byte_size(bin) == 16

      assert {:ok, roundtripped} = Types.uuid_binary_to_string(bin)
      assert String.downcase(roundtripped) == String.downcase(uuid)
    end

    test "invalid uuid strings are rejected" do
      assert :error = Types.uuid_string_to_binary("definitely not a uuid")
    end

    test "invalid binaries are rejected" do
      assert :error = Types.uuid_binary_to_string(<<1, 2, 3>>)
    end
  end

  describe "valid_cql_types/0" do
    test "includes the core ScyllaDB primitives" do
      valid = Types.valid_cql_types()

      assert :text in valid
      assert :int in valid
      assert :uuid in valid
      assert :boolean in valid
      assert :timestamp in valid
    end
  end
end
