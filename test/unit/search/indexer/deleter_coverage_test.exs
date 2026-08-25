defmodule AshScylla.Search.Indexer.DeleterCoverageTest do
  @moduledoc "Covers error propagation through delete/3 and delete_field/4."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Indexer.Deleter

  @uuid "550e8400-e29b-41d4-a716-446655440000"

  # Field maps fetch fine; deleting the posting rows fails.
  defmodule Src2PostingDeleteFailRepo do
    def query("SELECT field, terms" <> _, _params), do: {:ok, %{rows: [["title", %{"t" => 1}]]}}

    def query(cql, _params) do
      if String.contains?(cql, "search_post_terms"),
        do: {:error, :posting_delete_fail},
        else: {:ok, %{rows: []}}
    end
  end

  defmodule Src2TwoFieldRepo do
    def query("SELECT field, terms" <> _, _),
      do: {:ok, %{rows: [["title", %{"solo" => 1, "shared" => 2}], ["body", %{"shared" => 5}]]}}

    def query(_cql, _params), do: {:ok, %{rows: []}}
  end

  # Batch upserts fail; everything else succeeds.
  defmodule Src2BatchFailRepo do
    def query("SELECT field, terms" <> _, _),
      do: Src2TwoFieldRepo.query("SELECT field, terms", [])

    def query(cql, _params) do
      if String.contains?(cql, "BEGIN"),
        do: {:error, :batch_fail},
        else: {:ok, %{rows: []}}
    end
  end

  # The single-field row delete fails; everything else succeeds.
  defmodule Src2FieldRowDeleteFailRepo do
    def query("SELECT field, terms" <> _, _),
      do: Src2TwoFieldRepo.query("SELECT field, terms", [])

    def query(cql, _params) do
      if String.contains?(cql, "search_post_fields") and String.contains?(cql, "field = ?"),
        do: {:error, :field_row_delete_fail},
        else: {:ok, %{rows: []}}
    end
  end

  describe "delete/3" do
    test "returns the error when deleting postings fails after the fetch" do
      assert Deleter.delete(Src2PostingDeleteFailRepo, "ks", @uuid) ==
               {:error, :posting_delete_fail}
    end
  end

  describe "delete_field/4" do
    test "returns the error when lowering shared totals fails in a batch" do
      assert Deleter.delete_field(Src2BatchFailRepo, "ks", @uuid, "title") ==
               {:error, :batch_fail}
    end

    test "returns the error when clearing the field row fails" do
      assert Deleter.delete_field(Src2FieldRowDeleteFailRepo, "ks", @uuid, "title") ==
               {:error, :field_row_delete_fail}
    end
  end
end
