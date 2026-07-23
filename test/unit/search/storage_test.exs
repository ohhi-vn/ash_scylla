defmodule AshScylla.Search.StorageTest do
  @moduledoc "Tests for the storage schema module."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Storage

  describe "create_post_terms_cql/1" do
    test "generates valid CQL" do
      cql = Storage.create_post_terms_cql("my_keyspace")

      assert String.contains?(cql, "CREATE TABLE IF NOT EXISTS")
      assert String.contains?(cql, "my_keyspace")
      assert String.contains?(cql, "search_post_terms")
      assert String.contains?(cql, "PRIMARY KEY ((term, shard), post_id, field)")
    end
  end

  describe "create_post_fields_cql/1" do
    test "generates valid CQL" do
      cql = Storage.create_post_fields_cql("my_keyspace")

      assert String.contains?(cql, "CREATE TABLE IF NOT EXISTS")
      assert String.contains?(cql, "search_post_fields")
      assert String.contains?(cql, "PRIMARY KEY (post_id, field)")
    end
  end

  describe "shard_for/2" do
    test "returns consistent shard for same term" do
      shard1 = Storage.shard_for("phoenix")
      shard2 = Storage.shard_for("phoenix")
      assert shard1 == shard2
    end

    test "distributes across shard range" do
      shards = Enum.map(1..100, fn i -> Storage.shard_for("term#{i}") end)
      assert Enum.max(shards) < 16
      assert Enum.min(shards) >= 0
    end
  end
end
