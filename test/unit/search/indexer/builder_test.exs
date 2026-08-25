defmodule AshScylla.Search.Indexer.BuilderTest do
  use ExUnit.Case, async: true

  alias AshScylla.Search.Indexer.Builder

  @uuid "550e8400-e29b-41d4-a716-446655440000"

  defmodule MockRepo do
    def query(_cql, _params), do: {:error, :mock_error}
  end

  defmodule CaptureRepo do
    def query(cql, _params) do
      send(self(), {:cql, cql})
      {:ok, %{rows: []}}
    end
  end

  describe "index/4" do
    test "rejects invalid post_id without touching the repo" do
      assert {:error, reason} =
               Builder.index(MockRepo, "ks", "not-a-uuid", %{"title" => [{"hello", 1}]})

      assert is_binary(reason)
    end

    test "returns :ok for empty field map without writing" do
      assert Builder.index(CaptureRepo, "ks", @uuid, %{}) == :ok
      refute_received {:cql, _}
    end

    test "returns {:error, :mock_error} when mock repo returns error" do
      assert Builder.index(MockRepo, "ks", @uuid, %{"title" => [{"hello", 1}]}) ==
               {:error, :mock_error}
    end

    test "aggregates shared terms across fields into one posting row" do
      fields = %{
        "title" => [{"elixir", 2}, {"phoenix", 1}],
        "body" => [{"elixir", 3}]
      }

      assert Builder.index(CaptureRepo, "ks", @uuid, fields) == :ok
      assert_received {:cql, cql}

      # document-level posting: elixir total = 2 + 3 = 5, exactly one row
      assert cql =~ ~r/'elixir', \d+, #{@uuid}, 5/
      assert length(Regex.scan(~r/\(term, shard, post_id, tf\)/, cql)) == 2
      assert cql =~ "(term, shard, post_id, tf)"

      # per-field maps preserved for diffing
      assert cql =~ "'title', {'elixir': 2, 'phoenix': 1}"
      assert cql =~ "'body', {'elixir': 3}"
    end

    test "skips empty field maps in the fields table" do
      assert Builder.index(CaptureRepo, "ks", @uuid, %{"empty" => [], "title" => [{"hi", 1}]}) ==
               :ok

      assert_received {:cql, cql}
      assert cql =~ "'title'"
      refute cql =~ "'empty'"
    end
  end

  describe "build_postings_batch_cql/3" do
    test "builds a postings-only batch" do
      {:ok, cql} = Builder.build_postings_batch_cql("ks", @uuid, [{"run", 3}])

      assert cql =~ "BEGIN UNLOGGED BATCH"
      assert cql =~ "'run'"
      refute cql =~ "search_post_fields"
    end

    test "returns {:error, :batch_too_large} for oversized batches" do
      huge = [{String.duplicate("a", 600_000), 1}, {String.duplicate("b", 600_000), 1}]
      assert Builder.build_postings_batch_cql("ks", @uuid, huge) == {:error, :batch_too_large}
    end
  end

  describe "build_batch_cql/3" do
    test "returns {:error, :batch_too_large} for oversized batches" do
      huge_term = {String.duplicate("a", 600_000), 1}

      assert Builder.build_batch_cql("ks", @uuid, %{"f" => [huge_term, huge_term]}) ==
               {:error, :batch_too_large}
    end
  end
end
