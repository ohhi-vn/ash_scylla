defmodule AshScylla.BatchAsyncEdgeTest do
  @moduledoc """
  Covers AshScylla.DataLayer.Batch async-batch edge paths: default options,
  task exits, invalid-statement detection, and partition-key hashing.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Batch

  defmodule FvxBatchRepo do
    def query(_query, _params, _opts), do: {:ok, %Xandra.Page{content: []}}
  end

  defmodule FvxNoPkResource do
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      table("fvx_no_pk")
    end

    attributes do
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:read])
    end
  end

  describe "batch_insert_async/3" do
    test "uses default concurrency and batch-size options" do
      statements = [
        {"INSERT INTO fvx (id) VALUES (?)", [1]},
        {"INSERT INTO fvx (id) VALUES (?)", [2]},
        {"INSERT INTO fvx (id) VALUES (?)", []}
      ]

      assert {:ok, results} = Batch.batch_insert_async(FvxBatchRepo, statements)
      assert length(results) == 3
    end

    test "raises ArgumentError listing the first invalid statement" do
      assert_raise ArgumentError, ~r/Invalid batch statement: :garbage/, fn ->
        Batch.batch_insert(FvxBatchRepo, [
          {"INSERT INTO fvx (id) VALUES (?)", [1]},
          :garbage
        ])
      end
    end
  end

  describe "partition_key_hash/2" do
    test "hashes multiple pk values as a list" do
      assert is_integer(Batch.partition_key_hash([1, 2], [:id, :tenant]))

      assert Batch.partition_key_hash([1, 2], [:id, :tenant]) ==
               Batch.partition_key_hash([1, 2], [:id, :tenant])

      refute Batch.partition_key_hash([2, 1], [:id, :tenant]) ==
               Batch.partition_key_hash([1, 2], [:id, :tenant])
    end

    test "returns 0 for empty params with explicit pk columns" do
      assert Batch.partition_key_hash([], [:id]) == 0
    end
  end

  describe "partition_key_columns/1" do
    test "returns nil for a nil resource" do
      assert Batch.partition_key_columns(nil) == nil
    end

    test "returns the first primary key attribute for a resource" do
      assert Batch.partition_key_columns(AshScylla.TestResource) == [:id]
    end

    test "returns nil for a resource without primary key attributes" do
      assert Batch.partition_key_columns(FvxNoPkResource) == nil
    end
  end

  describe "partition_key/2" do
    test "collects primary key values present on the record" do
      record = %{id: "abc", name: "ignored"}

      assert Batch.partition_key(record, AshScylla.TestResource) == %{id: "abc"}
    end
  end

  describe "chunk_batch/2 and defaults" do
    test "chunks by max_statements_per_batch option" do
      statements = Enum.map(1..5, &{"Q", [&1]})
      chunks = Batch.chunk_batch(statements, max_statements_per_batch: 2)

      assert length(chunks) == 3
      assert length(hd(chunks)) == 2
    end

    test "exposes the default max statements per batch" do
      assert Batch.default_max_statements_per_batch() > 0
    end
  end
end
