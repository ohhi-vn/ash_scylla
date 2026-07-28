defmodule AshScylla.SearchTest do
  use ExUnit.Case, async: true

  alias AshScylla.Search

  defmodule MockLookupRepo do
    def query(_cql, _params) do
      {:ok, %{rows: []}}
    end
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
  end

  describe "delegated functions" do
    defmodule MockStorageRepo do
      def query(_cql, _params), do: {:ok, %{rows: []}}
    end

    test "create_tables/2 delegates to Storage" do
      assert Search.create_tables(MockStorageRepo, "ks") == :ok
    end

    test "drop_tables/2 delegates to Storage" do
      assert Search.drop_tables(MockStorageRepo, "ks") == :ok
    end

    test "index/5 delegates to Indexer" do
      assert Search.index(MockStorageRepo, "ks", "post-1", %{title: "hello"}) == :ok
    end

    test "update/5 delegates to Indexer" do
      assert Search.update(MockStorageRepo, "ks", "post-1", %{title: "updated"}) == :ok
    end

    test "delete/3 delegates to Indexer" do
      assert Search.delete(MockStorageRepo, "ks", "post-1") == :ok
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
