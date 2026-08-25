defmodule AshScylla.SearchTest do
  use ExUnit.Case, async: true

  alias AshScylla.Search

  defmodule MockLookupRepo do
    def query(_cql, _params) do
      {:ok, %{rows: []}}
    end
  end

  # In-memory inverted index served by term, rows in Xandra shape.
  defmodule IndexedRepo do
    @postings %{
      "phoenix" => [["p1", 2], ["p2", 1]],
      "framework" => [["p2", 1]]
    }

    def query(_cql, [term]), do: {:ok, %{rows: Map.get(@postings, term, [])}}
  end

  describe "search/4" do
    test "returns {:error, :empty_query} for empty query" do
      assert Search.search(nil, "ks", "") == {:error, :empty_query}
    end

    test "returns {:ok, page} with empty entries when no results" do
      result = Search.search(MockLookupRepo, "ks", "hello")
      assert {:ok, page} = result
      assert page.entries == []
      assert page.page_number == 1
    end

    test "accepts custom page size option" do
      result = Search.search(MockLookupRepo, "ks", "hello", page_size: 10)
      assert {:ok, page} = result
      assert page.page_size == 10
    end

    test "accepts ranking strategy option" do
      assert {:ok, _page} = Search.search(MockLookupRepo, "ks", "hello", strategy: :bm25)
    end

    test "accepts num_shards option" do
      assert {:ok, _page} = Search.search(MockLookupRepo, "ks", "hello", num_shards: 8)
    end

    test "full pipeline applies exclusions and ranks by tf" do
      assert {:ok, page} = Search.search(IndexedRepo, "ks", "phoenix -framework")
      assert page.entries == [{"p1", 2.0}]
      assert page.total_count == 1

      assert {:ok, page} = Search.search(IndexedRepo, "ks", "phoenix NOT framework")
      assert page.entries == [{"p1", 2.0}]
    end

    test "full pipeline errors on pure negative query" do
      assert Search.search(IndexedRepo, "ks", "-phoenix") == {:error, :missing_positive_term}
    end

    test "capitalized stop words are treated like any other stop word" do
      assert {:ok, page} = Search.search(IndexedRepo, "ks", "The phoenix")
      assert page.entries == [{"p1", 2.0}, {"p2", 1.0}]
    end

    test "bm25 derives usable stats when none are supplied" do
      {:ok, page} = Search.search(IndexedRepo, "ks", "phoenix OR framework", strategy: :bm25)

      assert Enum.all?(page.entries, fn {_id, score} -> score > 0.0 end)
    end
  end

  @post_id "550e8400-e29b-41d4-a716-446655440000"

  describe "delegated functions" do
    defmodule MockStorageRepo do
      def query("SELECT" <> _, _params), do: {:ok, %{rows: []}}
      def query(_cql, _params), do: {:ok, %{rows: []}}
    end

    test "create_tables/2 delegates to Storage" do
      assert Search.create_tables(MockStorageRepo, "ks") == :ok
    end

    test "drop_tables/2 delegates to Storage" do
      assert Search.drop_tables(MockStorageRepo, "ks") == :ok
    end

    test "index/5 delegates to Indexer" do
      assert Search.index(MockStorageRepo, "ks", @post_id, %{title: "hello"}) == :ok
    end

    test "update/5 delegates to Indexer" do
      assert Search.update(MockStorageRepo, "ks", @post_id, %{title: "updated"}) == :ok
    end

    test "delete/3 delegates to Indexer" do
      assert Search.delete(MockStorageRepo, "ks", @post_id) == :ok
    end

    test "index/5 rejects invalid post ids" do
      assert {:error, _} = Search.index(MockStorageRepo, "ks", "not-a-uuid", %{title: "x"})
    end
  end

  describe "search!/4" do
    test "raises on empty query" do
      assert_raise RuntimeError, ~r/Search failed/, fn ->
        Search.search!(nil, "ks", "")
      end
    end
  end
end
