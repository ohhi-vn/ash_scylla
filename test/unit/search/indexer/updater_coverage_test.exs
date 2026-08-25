defmodule AshScylla.Search.Indexer.UpdaterCoverageTest do
  @moduledoc "Covers write_fields/4 error propagation in apply_diff/6."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Indexer.Updater

  @uuid "550e8400-e29b-41d4-a716-446655440000"

  # Postings statements succeed; the field-row rewrite fails.
  defmodule Src2FieldsWriteFailRepo do
    def query(cql, _params) do
      if String.contains?(cql, "search_post_fields"),
        do: {:error, :fields_write_fail},
        else: {:ok, %{rows: []}}
    end
  end

  test "apply_diff/6 returns the error from a failing field-row statement" do
    assert Updater.apply_diff(Src2FieldsWriteFailRepo, "ks", @uuid, [], [], %{
             "title" => [{"elixir", 1}]
           }) == {:error, :fields_write_fail}
  end
end
