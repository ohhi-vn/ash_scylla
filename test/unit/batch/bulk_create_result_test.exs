defmodule AshScylla.BulkCreateResultTest do
  @moduledoc """
  Tests for bulk_create result handling.
  Covers: Issue #22 (batch_insert returns just :ok even if some batches succeed)
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer.Batch

  defmodule SuccessRepo do
    @moduledoc false
    def query(_q, _p, _opts \\ []), do: {:ok, %{}}
  end

  defmodule FailingRepo do
    @moduledoc false
    def query(_q, _p, _opts \\ []), do: {:error, :batch_failed}
  end

  describe "batch_insert error handling" do
    test "returns error when batch fails" do
      statements = [
        {"INSERT INTO t (id) VALUES (?)", [1]}
      ]

      assert {:error, :batch_failed} = Batch.batch_insert(FailingRepo, statements)
    end

    test "returns ok when batch succeeds" do
      statements = [
        {"INSERT INTO t (id) VALUES (?)", [1]}
      ]

      assert {:ok, _} = Batch.batch_insert(SuccessRepo, statements)
    end
  end

  describe "batch_insert_async error handling" do
    test "returns error when any batch group fails" do
      statements = [
        {"INSERT INTO t (id) VALUES (?)", [1]}
      ]

      assert {:error, :batch_failed} =
               Batch.batch_insert_async(FailingRepo, statements, max_concurrency: 1)
    end

    test "returns ok when all batch groups succeed" do
      statements = [
        {"INSERT INTO t (id) VALUES (?)", [1]},
        {"INSERT INTO t (id) VALUES (?)", [2]}
      ]

      assert {:ok, _} =
               Batch.batch_insert_async(SuccessRepo, statements, max_concurrency: 1)
    end
  end
end
