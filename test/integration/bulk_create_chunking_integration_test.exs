defmodule AshScylla.BulkCreateChunkingIntegrationTest do
  @moduledoc """
  Integration tests for bulk_create chunking behavior.

  ScyllaDB has batch size limits (warns at ~128KB, fails at ~256KB).
  These tests verify that AshScylla chunks large bulk_creates automatically.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshScylla.DataLayer.Batch

  describe "batch chunking" do
    test "chunk_batch splits statements into safe sizes" do
      statements =
        for i <- 1..500 do
          {"INSERT INTO users (id, name) VALUES (?, ?)", [uid(), "User #{i}"]}
        end

      # Default chunk size is 500
      chunks = Batch.chunk_batch(statements)
      assert length(chunks) == 1

      # With smaller chunk size
      chunks = Batch.chunk_batch(statements, max_statements_per_batch: 100)
      assert length(chunks) == 5
      assert Enum.all?(chunks, fn chunk -> length(chunk) <= 100 end)
    end

    test "chunk_batch preserves all statements" do
      statements =
        for i <- 1..250 do
          {"INSERT INTO users (id, name) VALUES (?, ?)", [uid(), "User #{i}"]}
        end

      chunks = Batch.chunk_batch(statements, max_statements_per_batch: 100)
      flat = List.flatten(chunks)
      assert length(flat) == 250
    end

    test "chunk_batch with empty list" do
      assert Batch.chunk_batch([]) == []
    end

    test "default_max_statements_per_batch is reasonable" do
      max = Batch.default_max_statements_per_batch()
      assert max == 500
      assert max > 0
    end
  end

  defp uid do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    <<u0::48, 4::4, u1::12, 2::2, u2::62>>
  end
end
