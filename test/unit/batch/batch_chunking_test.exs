defmodule AshScylla.DataLayer.BatchChunkingTest do
  @moduledoc """
  Tests for batch chunking functionality.
  Covers: batch_insert_async chunking and chunk_batch/2 utility.
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer.Batch

  defmodule ChunkTrackingRepo do
    @moduledoc false

    def start_link do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def get_calls do
      Agent.get(__MODULE__, & &1)
    end

    def clear_calls do
      Agent.update(__MODULE__, fn _ -> [] end)
    end

    def query(_q, _p, _opts \\ []) do
      Agent.update(__MODULE__, fn calls -> [:query | calls] end)
      {:ok, %{}}
    end
  end

  describe "chunk_batch/2" do
    test "splits statements into chunks of default size" do
      statements = for i <- 1..1000, do: {"INSERT INTO t (id) VALUES (?)", [i]}
      chunks = Batch.chunk_batch(statements)
      assert length(chunks) == 2
      assert length(hd(chunks)) == 500
    end

    test "handles statements fewer than chunk size" do
      statements = for i <- 1..10, do: {"INSERT INTO t (id) VALUES (?)", [i]}
      chunks = Batch.chunk_batch(statements)
      assert length(chunks) == 1
      assert length(hd(chunks)) == 10
    end

    test "handles empty list" do
      assert Batch.chunk_batch([]) == []
    end

    test "accepts custom max_statements_per_batch" do
      statements = for i <- 1..100, do: {"INSERT INTO t (id) VALUES (?)", [i]}
      chunks = Batch.chunk_batch(statements, max_statements_per_batch: 25)
      assert length(chunks) == 4
      assert Enum.all?(chunks, &(length(&1) == 25))
    end

    test "last chunk may be smaller than max" do
      statements = for i <- 1..101, do: {"INSERT INTO t (id) VALUES (?)", [i]}
      chunks = Batch.chunk_batch(statements, max_statements_per_batch: 50)
      assert length(chunks) == 3
      assert length(Enum.at(chunks, 0)) == 50
      assert length(Enum.at(chunks, 1)) == 50
      assert length(Enum.at(chunks, 2)) == 1
    end
  end

  describe "default_max_statements_per_batch/0" do
    test "returns 500" do
      assert Batch.default_max_statements_per_batch() == 500
    end
  end

  describe "batch_insert_async/3 with chunking" do
    setup do
      case Process.whereis(ChunkTrackingRepo) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end

      {:ok, _pid} = ChunkTrackingRepo.start_link()
      :ok
    end

    test "chunks large statement lists into multiple batches" do
      ChunkTrackingRepo.clear_calls()

      # Create more statements than the default chunk size (500)
      statements = for i <- 1..600, do: {"INSERT INTO t (id) VALUES (?)", [i]}

      assert {:ok, _results} =
               Batch.batch_insert_async(ChunkTrackingRepo, statements, max_concurrency: 1)

      calls = ChunkTrackingRepo.get_calls()
      # Should have been called at least twice (600 statements / 500 per chunk = 2 chunks)
      assert length(calls) >= 2
    end

    test "handles statements within single chunk" do
      ChunkTrackingRepo.clear_calls()

      # Use same partition key so all statements group together
      statements = for i <- 1..100, do: {"INSERT INTO t (id) VALUES (?)", ["same_pk"]}

      assert {:ok, _results} =
               Batch.batch_insert_async(ChunkTrackingRepo, statements, max_concurrency: 1)

      calls = ChunkTrackingRepo.get_calls()
      # All 100 statements are in one chunk (within default 500), one group call
      assert length(calls) == 1
    end

    test "respects custom max_statements_per_batch" do
      ChunkTrackingRepo.clear_calls()

      # Use same partition key so grouping doesn't split them
      statements = for i <- 1..50, do: {"INSERT INTO t (id) VALUES (?)", ["same_pk"]}

      assert {:ok, _results} =
               Batch.batch_insert_async(ChunkTrackingRepo, statements,
                 max_concurrency: 1,
                 max_statements_per_batch: 10
               )

      calls = ChunkTrackingRepo.get_calls()
      # 50 statements / 10 per chunk = 5 chunks, each with 1 group = 5 calls
      assert length(calls) == 5
    end
  end
end
