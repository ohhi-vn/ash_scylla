defmodule AshScylla.DataLayer.TypesUnitTest do
  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Types

  describe "field_type_to_cql/1" do
    test "delegates to cql_type/1" do
      assert Types.field_type_to_cql(:text) == "TEXT"
      assert Types.field_type_to_cql(:uuid) == "UUID"
      assert Types.field_type_to_cql(:int) == "INT"
      assert Types.field_type_to_cql(:unknown) == "TEXT"
    end
  end

  describe "cql_element_type/1" do
    test "delegates to cql_type/1" do
      assert Types.cql_element_type(:int) == "INT"
      assert Types.cql_element_type(:float) == "DOUBLE"
      assert Types.cql_element_type(:text) == "TEXT"
    end
  end

  describe "valid_cql_types/0" do
    test "returns a list of atoms" do
      types = Types.valid_cql_types()
      assert is_list(types)
      assert Enum.all?(types, &is_atom/1)
    end

    test "includes common CQL types" do
      types = Types.valid_cql_types()
      assert :text in types
      assert :uuid in types
      assert :int in types
      assert :boolean in types
    end
  end

  describe "ash_type_to_cql_type/2 with :tuple" do
    test "handles tuple types" do
      result = Types.ash_type_to_cql_type({:tuple, [:string, :integer]}, [])
      assert result == "TUPLE<TEXT, BIGINT>"
    end

    test "handles empty tuple" do
      assert Types.ash_type_to_cql_type({:tuple, []}, []) == "TUPLE<>"
    end

    test "handles nested tuples" do
      result = Types.ash_type_to_cql_type({:tuple, [:string, {:array, :integer}]}, [])
      assert result == "TUPLE<TEXT, LIST<BIGINT>>"
    end
  end

  describe "ash_type_to_cql_type/2 catch-all" do
    test "warns and returns TEXT for unknown types" do
      assert Types.ash_type_to_cql_type(:not_a_real_type_12345, []) == "TEXT"
    end

    test "handles nil type" do
      assert Types.ash_type_to_cql_type(nil, []) == "TEXT"
    end
  end

  describe "ash_type_to_cql_type/2 with :udt" do
    test "generates frozen UDT with string type_name" do
      assert Types.ash_type_to_cql_type(:udt, type_name: "my_address") == "frozen<my_address>"
    end

    test "generates frozen UDT with atom type_name" do
      assert Types.ash_type_to_cql_type(:udt, type_name: :MyAddress) == "frozen<MyAddress>"
    end

    test "falls back to 'undefined' when no type_name given" do
      assert Types.ash_type_to_cql_type(:udt, []) == "frozen<undefined>"
    end
  end

  describe "ash_type_to_cql_type/2 with Ash.Type module constants" do
    test "Ash.Type.Float maps to DOUBLE" do
      assert Types.ash_type_to_cql_type(Ash.Type.Float, []) == "DOUBLE"
    end

    test "Ash.Type.Double maps to DOUBLE" do
      assert Types.ash_type_to_cql_type(Ash.Type.Double, []) == "DOUBLE"
    end
  end

  describe "uuid_string_to_binary/1" do
    test "converts valid UUID string to binary" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      assert {:ok, bin} = Types.uuid_string_to_binary(uuid)
      assert is_binary(bin)
      assert byte_size(bin) == 16
    end

    test "returns :error for invalid UUID string" do
      assert Types.uuid_string_to_binary("not-a-uuid") == :error
    end

    test "returns :error for empty string" do
      assert Types.uuid_string_to_binary("") == :error
    end

    test "returns :error for non-binary input" do
      assert Types.uuid_string_to_binary(123) == :error
      assert Types.uuid_string_to_binary(nil) == :error
    end

    test "handles UUID with mixed case hex" do
      uuid = "550E8400-E29B-41D4-A716-446655440000"
      assert {:ok, bin} = Types.uuid_string_to_binary(uuid)
      assert byte_size(bin) == 16
    end

    test "returns :error for UUID with wrong segment length" do
      assert Types.uuid_string_to_binary("550e8400-e29b-41d4-a716-44665544000") == :error
    end

    test "returns :error for UUID with invalid hex" do
      assert Types.uuid_string_to_binary("zzzzzzzz-e29b-41d4-a716-446655440000") == :error
    end
  end

  describe "uuid_binary_to_string/1" do
    test "converts valid binary to UUID string" do
      uuid_str = "550e8400-e29b-41d4-a716-446655440000"
      {:ok, bin} = Types.uuid_string_to_binary(uuid_str)
      assert {:ok, result} = Types.uuid_binary_to_string(bin)
      assert String.downcase(result) == uuid_str
    end

    test "returns :error for non-16-byte binary" do
      assert Types.uuid_binary_to_string(<<1, 2, 3>>) == :error
    end

    test "returns :error for empty binary" do
      assert Types.uuid_binary_to_string(<<>>) == :error
    end

    test "round-trips a UUID string through both conversions" do
      original = "550e8400-e29b-41d4-a716-446655440000"
      {:ok, bin} = Types.uuid_string_to_binary(original)
      {:ok, result} = Types.uuid_binary_to_string(bin)
      assert String.downcase(result) == original
    end

    test "round-trips another UUID" do
      original = "00000000-0000-0000-0000-000000000000"
      {:ok, bin} = Types.uuid_string_to_binary(original)
      {:ok, result} = Types.uuid_binary_to_string(bin)
      assert result == original
    end
  end
end
