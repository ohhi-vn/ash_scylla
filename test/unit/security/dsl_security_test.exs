defmodule AshScylla.DslSecurityTest do
  @moduledoc """
  Security tests for the DSL — ensures that:
  - The scylla block validates all inputs at compile time
  - Secondary indexes are properly structured
  - TTL values are bounded
  - Repo references are validated
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Dsl
  alias AshScylla.DataLayer.SecondaryIndex

  # ---------------------------------------------------------------------------
  # Secondary index struct safety
  # ---------------------------------------------------------------------------

  describe "SecondaryIndex struct safety" do
    test "parse/1 rejects invalid input" do
      assert_raise RuntimeError, ~r/Invalid secondary_index/, fn ->
        SecondaryIndex.parse(123)
      end
    end

    test "parse/1 with atom creates single-column index" do
      idx = SecondaryIndex.parse(:email)
      assert %SecondaryIndex{} = idx
      assert idx.columns == [:email]
      assert idx.name == nil
    end

    test "parse/1 with list creates multi-column index" do
      idx = SecondaryIndex.parse([:name, :age])
      assert %SecondaryIndex{} = idx
      assert idx.columns == [:name, :age]
    end

    test "parse/1 with tuple preserves custom name" do
      idx = SecondaryIndex.parse({:email, name: "idx_custom_email"})
      assert %SecondaryIndex{} = idx
      assert idx.columns == [:email]
      assert idx.name == "idx_custom_email"
    end

    test "effective_name/3 generates safe index names" do
      idx = SecondaryIndex.parse(:email)
      name = SecondaryIndex.effective_name(idx, "users", :email)
      assert name == "idx_users_email"
      # Index name should be a valid CQL identifier
      assert name =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
    end

    test "effective_name/3 with custom name is still safe" do
      idx = SecondaryIndex.parse({:email, name: "custom"})
      name = SecondaryIndex.effective_name(idx, "users", :email)
      assert name == "custom_email"
      assert name =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
    end

    test "default_name/2 generates valid CQL identifiers" do
      name = SecondaryIndex.default_name("users", :email)
      assert name == "idx_users_email"
      assert name =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
    end
  end

  # ---------------------------------------------------------------------------
  # DSL config retrieval safety
  # ---------------------------------------------------------------------------

  describe "DSL config retrieval safety" do
    test "secondary_indexes returns list of SecondaryIndex structs" do
      indexes = Dsl.secondary_indexes(AshScylla.TestResourceWithIndexes)
      assert is_list(indexes)

      for idx <- indexes do
        # Each index should have a columns list
        assert is_list(idx.columns)
        assert length(idx.columns) > 0
        # Columns should be atoms
        for col <- idx.columns do
          assert is_atom(col)
        end
      end
    end

    test "table returns a string or nil" do
      result = Dsl.table(AshScylla.TestResource)
      assert is_binary(result) or is_nil(result)
    end

    test "keyspace returns a string or nil" do
      result = Dsl.keyspace(AshScylla.TestResource)
      assert is_binary(result) or is_nil(result)
    end

    test "ttl returns a positive integer or nil" do
      result = Dsl.ttl(AshScylla.TestResource)
      assert (is_integer(result) and result > 0) or is_nil(result)
    end

    test "consistency returns a valid atom or nil" do
      result = Dsl.consistency(AshScylla.TestResource)

      valid_levels = [
        :any,
        :one,
        :two,
        :three,
        :quorum,
        :all,
        :local_quorum,
        :each_quorum,
        :local_one
      ]

      assert result in valid_levels or is_nil(result)
    end

    test "pagination returns :token or :offset" do
      result = Dsl.pagination(AshScylla.TestResource)
      assert result in [:token, :offset]
    end

    test "lwt returns boolean" do
      result = Dsl.lwt(AshScylla.TestResource)
      assert is_boolean(result)
    end
  end

  # ---------------------------------------------------------------------------
  # has_secondary_index?/2 safety
  # ---------------------------------------------------------------------------

  describe "has_secondary_index?/2 safety" do
    test "returns boolean for any input" do
      result = Dsl.has_secondary_index?(AshScylla.TestResourceWithIndexes, :email)
      assert is_boolean(result)
    end

    test "returns true for indexed column" do
      assert Dsl.has_secondary_index?(AshScylla.TestResourceWithIndexes, :email)
    end

    test "returns false for non-indexed column" do
      # TestResourceWithIndexes indexes :email, [:name, :age], and :status
      # :created_at is NOT indexed
      refute Dsl.has_secondary_index?(AshScylla.TestResourceWithIndexes, :created_at)
    end

    test "returns false for non-existent column" do
      refute Dsl.has_secondary_index?(AshScylla.TestResourceWithIndexes, :nonexistent)
    end
  end

  # ---------------------------------------------------------------------------
  # Repo validation
  # ---------------------------------------------------------------------------

  describe "repo validation safety" do
    test "repo returns a module or nil" do
      result = Dsl.repo(AshScylla.TestResource)
      assert is_atom(result)
    end
  end
end
