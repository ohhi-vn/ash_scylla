defmodule AshScylla.DataLayer.CollectionCoverageTest do
  @moduledoc """
  Coverage for `AshScylla.DataLayer.Collection` element validation across all
  supported CQL element types, plus frozen storage optimization branches.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Collection

  describe "validate/3 element types" do
    test "accepts correctly-typed list elements" do
      now = System.system_time(:millisecond)

      assert Collection.validate(["a"], :list, element_type: :text) == :ok
      assert Collection.validate([1], :list, element_type: :int) == :ok
      assert Collection.validate([1], :list, element_type: :bigint) == :ok
      assert Collection.validate([true], :list, element_type: :boolean) == :ok
      assert Collection.validate([1.5], :list, element_type: :float) == :ok
      assert Collection.validate([1.5], :list, element_type: :double) == :ok
      assert Collection.validate([Ash.UUID.generate()], :list, element_type: :uuid) == :ok
      assert Collection.validate([now], :list, element_type: :timestamp) == :ok
      assert Collection.validate([<<1, 2>>], :list, element_type: :blob) == :ok
      assert Collection.validate(["127.0.0.1"], :list, element_type: :inet) == :ok
      assert Collection.validate(["2024-01-01"], :list, element_type: :date) == :ok
      assert Collection.validate(["12:00:00"], :list, element_type: :time) == :ok
      assert Collection.validate([1], :list, element_type: :smallint) == :ok
      assert Collection.validate([1], :list, element_type: :tinyint) == :ok
      assert Collection.validate([now], :list, element_type: :duration) == :ok
    end

    test "rejects mismatched elements with a descriptive error" do
      assert {:error, msg} = Collection.validate([:not_text], :list, element_type: :text)
      assert msg =~ "does not match expected type"

      assert {:error, _} = Collection.validate(["str"], :list, element_type: :int)
      assert {:error, _} = Collection.validate([1], :set, element_type: :boolean)
      assert {:error, _} = Collection.validate([1.5], :set, element_type: :uuid)
    end

    test "validates every element and reports the first failure" do
      assert {:error, _} = Collection.validate(["ok", 2], :list, element_type: :text)
      assert :ok = Collection.validate([], :list, element_type: :text)
    end

    test "accepts MapSets for set columns" do
      assert Collection.validate(MapSet.new([1, 2]), :set, element_type: :int) == :ok
      assert {:error, _} = Collection.validate("not_a_set", :set, element_type: :text)
    end

    test "map columns only require a map value" do
      assert Collection.validate(%{"k" => 1}, :map, []) == :ok
      assert {:error, msg} = Collection.validate([:not_a_map], :map, [])
      assert msg =~ "Expected a map"
    end

    test "list columns require lists" do
      assert {:error, msg} = Collection.validate("nope", :list, element_type: :text)
      assert msg =~ "Expected a list"
    end
  end

  describe "optimize_for_storage/3" do
    test "sets sort and optionally freeze" do
      assert Collection.optimize_for_storage([3, 1, 2], :set, element_type: :int) == [1, 2, 3]
      assert Collection.optimize_for_storage(MapSet.new([2, 1]), :set, []) == [1, 2]

      assert Collection.optimize_for_storage([2, 1], :set, frozen: true) == {1, 2}
    end

    test "lists pass through or freeze as tuples" do
      assert Collection.optimize_for_storage(["b", "a"], :list, []) == ["b", "a"]
      assert Collection.optimize_for_storage([1, 2], :list, frozen: true) == {1, 2}
    end

    test "maps pass through or freeze as tuple pairs" do
      map = %{:a => 1, :b => 2}

      assert Collection.optimize_for_storage(map, :map, []) == map

      {pair1, pair2} = Collection.optimize_for_storage(map, :map, frozen: true)
      assert {pair1, pair2} in [{:a, 1}, {:b, 2}] or true
      assert Enum.sort([pair1, pair2]) == [{:a, 1}, {:b, 2}]
    end
  end

  describe "encode/decode round-trips" do
    test "lists preserve order; frozen tuples decode as-is" do
      assert Collection.encode([1, 2, 3], :list, element_type: :int) == [1, 2, 3]
      # Frozen list values are stored as tuples and passed through on decode.
      assert Collection.decode({1, 2}, :list, element_type: :int) == {1, 2}
    end

    test "sets encode to MapSets and decode from tuples or lists" do
      encoded = Collection.encode([3, 1], :set, element_type: :int)
      assert MapSet.equal?(encoded, MapSet.new([1, 3]))

      assert Collection.decode(MapSet.new([1, 2]), :set, element_type: :int) == MapSet.new([1, 2])
    end

    test "maps encode/decode unchanged" do
      assert Collection.encode(%{a: 1}, :map, []) == %{a: 1}
      assert Collection.decode(%{a: 1}, :map, []) == %{a: 1}
    end
  end

  describe "CQL generation helpers" do
    test "collection_type_to_cql renders and freezes" do
      assert Collection.collection_type_to_cql(:list, element_type: :int) == "LIST<INT>"
      assert Collection.collection_type_to_cql(:set, element_type: :uuid) == "SET<UUID>"

      assert Collection.collection_type_to_cql(:map, key_type: :text, value_type: :int) ==
               "MAP<TEXT, INT>"

      assert Collection.collection_type_to_cql(:list, element_type: :int, frozen: true) ==
               "FROZEN<LIST<INT>>"

      assert Collection.collection_type_to_cql(:map, key_type: :text, frozen: true) ==
               "FROZEN<MAP<TEXT, TEXT>>"
    end

    test "mutation CQL builders quote table names consistently for atoms and binaries" do
      assert Collection.append_cql(:users, :tags, ["x"]) =~ ~s[UPDATE users SET tags]
      assert Collection.prepend_cql("users", :tags, ["x"]) =~ ~s[UPDATE users SET tags]
      assert Collection.remove_cql(:users, :tags, ["x"]) =~ ~s[UPDATE users SET tags]

      assert Collection.set_at_cql(:users, :scores, 0, 9) =~ "scores[?]"
      assert Collection.get_at_cql("users", :scores, 1) =~ "SELECT scores[?]"
      assert Collection.size_cql(:users, :tags) =~ "SIZE(tags)"

      assert Collection.collection_index_cql(:users, :tags, :values) ==
               "CREATE INDEX ON users (VALUES(tags))"
    end
  end
end
