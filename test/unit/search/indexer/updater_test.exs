defmodule AshScylla.Search.Indexer.UpdaterTest do
  use ExUnit.Case, async: true

  alias AshScylla.Search.Indexer.Updater

  @uuid "550e8400-e29b-41d4-a716-446655440000"

  defmodule CaptureRepo do
    def query(cql, params) do
      send(self(), {:cql, {cql, params}})
      {:ok, %{rows: []}}
    end
  end

  defmodule FailingRepo do
    def query(_cql, _params), do: {:error, :mock_error}
  end

  describe "apply_diff/6" do
    test "no-op when nothing changes" do
      assert Updater.apply_diff(CaptureRepo, "ks", @uuid, [], [], %{}) == :ok
      refute_received {:cql, _}
    end

    test "rejects invalid post_id" do
      assert {:error, _} = Updater.apply_diff(FailingRepo, "ks", "bad-id", [{"a", 1}], [], %{})
    end

    test "upserts changed totals in a postings batch" do
      assert Updater.apply_diff(CaptureRepo, "ks", @uuid, [{"elixir", 5}, {"run", 2}], [], %{
               "body" => [{"elixir", 5}]
             }) == :ok

      assert_received {:cql, {batch_cql, []}}
      assert batch_cql =~ ~r/'elixir', \d+, #{@uuid}, 5/
      assert batch_cql =~ ~r/'run', \d+, #{@uuid}, 2/
      refute batch_cql =~ "search_post_fields"

      assert_received {:cql, {fields_cql, [@uuid, "body"]}}
      assert fields_cql =~ "SET terms = {'elixir': 5}"
    end

    test "deletes zeroed terms with bound parameters" do
      assert Updater.apply_diff(CaptureRepo, "ks", @uuid, [], ["stale"], %{}) == :ok

      assert_received {:cql, {delete_cql, [term, post_id]}}
      assert delete_cql =~ ~r/DELETE FROM .*search_post_terms/
      assert term == "stale"
      assert post_id == @uuid
    end

    test "deletes fields rows for emptied fields" do
      assert Updater.apply_diff(CaptureRepo, "ks", @uuid, [], [], %{"title" => []}) == :ok

      assert_received {:cql, {delete_cql, [@uuid, "title"]}}
      assert delete_cql =~ ~r/DELETE FROM .*search_post_fields/
    end

    test "returns error when the repo fails" do
      assert Updater.apply_diff(FailingRepo, "ks", @uuid, [{"a", 1}], [], %{"f" => [{"a", 1}]}) ==
               {:error, :mock_error}
    end
  end
end
