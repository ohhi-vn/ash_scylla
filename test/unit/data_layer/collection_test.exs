defmodule AshScylla.DataLayer.CollectionTest do
  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Collection

  describe "encode/3" do
    test "encodes a list" do
      assert Collection.encode([1, 2, 3], :list, []) == [1, 2, 3]
    end

    test "encodes a frozen list as tuple" do
      assert Collection.encode([1, 2, 3], :list, frozen: true) == {1, 2, 3}
    end

    test "encodes a set as MapSet" do
      result = Collection.encode([1, 2, 3], :set, [])
      assert result == MapSet.new([1, 2, 3])
    end

    test "encodes a frozen set as tuple" do
      result = Collection.encode([3, 1, 2], :set, frozen: true)
      assert is_tuple(result)
      assert Tuple.to_list(result) |> MapSet.new() == MapSet.new([1, 2, 3])
    end

    test "encodes a map" do
      result = Collection.encode(%{a: 1}, :map, [])
      assert result == %{a: 1}
    end

    test "encodes a frozen map as tuple" do
      result = Collection.encode(%{a: 1, b: 2}, :map, frozen: true)
      assert is_tuple(result)
      assert result |> Tuple.to_list() |> Map.new() == %{a: 1, b: 2}
    end
  end

  describe "decode/3" do
    test "decodes a list" do
      assert Collection.decode(["a", "b"], :list, []) == ["a", "b"]
    end

    test "decodes a frozen list from tuple" do
      assert Collection.decode({1, 2, 3}, :list, frozen: true) == [1, 2, 3]
    end

    test "decodes a set" do
      result = Collection.decode(MapSet.new([1, 2]), :set, [])
      assert result == MapSet.new([1, 2])
    end

    test "decodes a frozen set from tuple" do
      assert Collection.decode({1, 2, 3}, :set, frozen: true) == [1, 2, 3]
    end

    test "decodes a map" do
      assert Collection.decode(%{k: "v"}, :map, []) == %{k: "v"}
    end

    test "decodes a frozen map from tuple of key-value pairs" do
      result = Collection.decode({{:a, 1}, {:b, 2}}, :map, frozen: true)
      assert result == %{a: 1, b: 2}
    end
  end

  describe "append_cql/3" do
    test "generates CQL for atom table name" do
      assert Collection.append_cql(:users, :tags, ["new"]) ==
               "UPDATE users SET tags = tags + ? WHERE ..."
    end

    test "generates CQL for string table name" do
      assert Collection.append_cql("users", :tags, ["new"]) ==
               "UPDATE users SET tags = tags + ? WHERE ..."
    end
  end

  describe "prepend_cql/3" do
    test "generates CQL for prepending to a list" do
      assert Collection.prepend_cql(:users, :items, ["first"]) ==
               "UPDATE users SET items = ? + items WHERE ..."
    end

    test "generates CQL with string table name" do
      assert Collection.prepend_cql("users", :items, ["first"]) ==
               "UPDATE users SET items = ? + items WHERE ..."
    end
  end

  describe "remove_cql/3" do
    test "generates CQL for removing elements" do
      assert Collection.remove_cql(:users, :tags, ["old"]) ==
               "UPDATE users SET tags = tags - ? WHERE ..."
    end
  end

  describe "set_at_cql/4" do
    test "generates CQL for setting element by index" do
      assert Collection.set_at_cql(:users, :items, 0, "first") ==
               "UPDATE users SET items[?] = ? WHERE ..."
    end

    test "generates CQL for setting map key" do
      assert Collection.set_at_cql(:users, :metadata, "key", "val") ==
               "UPDATE users SET metadata[?] = ? WHERE ..."
    end
  end

  describe "get_at_cql/3" do
    test "generates CQL for accessing by index" do
      assert Collection.get_at_cql(:users, :items, 0) ==
               "SELECT items[?] FROM users WHERE ..."
    end

    test "generates CQL for accessing map by key" do
      assert Collection.get_at_cql(:users, :metadata, "key") ==
               "SELECT metadata[?] FROM users WHERE ..."
    end
  end

  describe "size_cql/2" do
    test "generates CQL for collection size" do
      assert Collection.size_cql(:users, :tags) ==
               "SELECT SIZE(tags) FROM users WHERE ..."
    end
  end

  describe "collection_index_cql/3" do
    test "generates CQL for VALUES index" do
      assert Collection.collection_index_cql(:users, :tags, :values) ==
               "CREATE INDEX ON users (VALUES(tags))"
    end

    test "generates CQL for KEYS index" do
      assert Collection.collection_index_cql(:users, :metadata, :keys) ==
               "CREATE INDEX ON users (KEYS(metadata))"
    end

    test "generates CQL for ENTRIES index" do
      assert Collection.collection_index_cql(:users, :metadata, :entries) ==
               "CREATE INDEX ON users (ENTRIES(metadata))"
    end

    test "generates CQL for FULL index" do
      assert Collection.collection_index_cql(:users, :frozen_data, :full) ==
               "CREATE INDEX ON users (FULL(frozen_data))"
    end
  end

  describe "contains_cql/3" do
    test "generates CONTAINS filter" do
      assert Collection.contains_cql(:users, :tags, "admin") == {"tags CONTAINS ?", ["admin"]}
    end
  end

  describe "contains_key_cql/3" do
    test "generates CONTAINS KEY filter" do
      assert Collection.contains_key_cql(:users, :metadata, "role") ==
               {"metadata CONTAINS KEY ?", ["role"]}
    end
  end

  describe "collection_type_to_cql/2" do
    test "generates LIST type CQL" do
      assert Collection.collection_type_to_cql(:list, element_type: :text) == "LIST<TEXT>"
    end

    test "generates SET type CQL" do
      assert Collection.collection_type_to_cql(:set, element_type: :int) == "SET<INT>"
    end

    test "generates MAP type CQL" do
      assert Collection.collection_type_to_cql(:map, key_type: :text, value_type: :int) ==
               "MAP<TEXT, INT>"
    end

    test "generates FROZEN type CQL" do
      assert Collection.collection_type_to_cql(:list, element_type: :text, frozen: true) ==
               "FROZEN<LIST<TEXT>>"
    end

    test "uses default element type" do
      assert Collection.collection_type_to_cql(:list, []) == "LIST<TEXT>"
    end
  end

  describe "validate/3" do
    test "accepts valid list" do
      assert Collection.validate(["a", "b"], :list, element_type: :text) == :ok
    end

    test "rejects non-list for list type" do
      assert {:error, msg} = Collection.validate("not_a_list", :list, element_type: :text)
      assert msg =~ "Expected a list"
    end

    test "accepts valid set" do
      assert Collection.validate([1, 2], :set, element_type: :int) == :ok
    end

    test "accepts MapSet as set" do
      assert Collection.validate(MapSet.new([1, 2]), :set, element_type: :int) == :ok
    end

    test "rejects non-set for set type" do
      assert {:error, msg} = Collection.validate("bad", :set, element_type: :int)
      assert msg =~ "Expected a set"
    end

    test "accepts valid map" do
      assert Collection.validate(%{a: 1}, :map, []) == :ok
    end

    test "rejects non-map for map type" do
      assert {:error, msg} = Collection.validate("bad", :map, [])
      assert msg =~ "Expected a map"
    end

    test "rejects element type mismatch in list" do
      assert {:error, msg} = Collection.validate([1, "two"], :list, element_type: :int)
      assert msg =~ "does not match expected type"
    end

    test "accepts empty list" do
      assert Collection.validate([], :list, element_type: :text) == :ok
    end
  end

  describe "optimize_for_storage/3" do
    test "sorts set values" do
      assert Collection.optimize_for_storage([3, 1, 2], :set, element_type: :int) == [1, 2, 3]
    end

    test "keeps list order" do
      assert Collection.optimize_for_storage([3, 1, 2], :list, element_type: :text) == [3, 1, 2]
    end

    test "freezes set as tuple" do
      result = Collection.optimize_for_storage([3, 1, 2], :set, frozen: true)
      assert result == {1, 2, 3}
    end

    test "freezes list as tuple" do
      assert Collection.optimize_for_storage([1, 2], :list, frozen: true) == {1, 2}
    end

    test "freezes map as tuple" do
      result = Collection.optimize_for_storage(%{b: 2, a: 1}, :map, frozen: true)
      assert is_tuple(result)
      assert result |> Tuple.to_list() |> Map.new() == %{a: 1, b: 2}
    end
  end
end
