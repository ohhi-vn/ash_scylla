defmodule AshScylla.Search.StorageCoverageTest do
  @moduledoc "Covers malformed-row handling in fetch_field_maps/3 and sum_field_maps/1."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Storage

  @uuid "550e8400-e29b-41d4-a716-446655440000"

  defmodule Src2JunkRowsRepo do
    def query(_cql, _params),
      do:
        {:ok,
         %{
           rows: [
             "junk",
             [:not_a_binary, %{}],
             ["title", %{"t" => 1}],
             ["body", "not-a-map"]
           ]
         }}
  end

  describe "fetch_field_maps/3" do
    test "skips malformed rows and normalizes non-map term values to empty maps" do
      assert Storage.fetch_field_maps(Src2JunkRowsRepo, "ks", @uuid) ==
               {:ok, %{"body" => %{}, "title" => %{"t" => 1}}}
    end
  end

  describe "sum_field_maps/1" do
    test "ignores field values that are neither maps nor keyword lists" do
      assert Storage.sum_field_maps(%{"f" => :junk, "g" => [{"a", 1}]}) == %{"a" => 1}
    end
  end
end
