defmodule AshScylla.Search.IndexerTest do
  use ExUnit.Case, async: true

  alias AshScylla.Search.Indexer

  defmodule MockFailingRepo do
    def query(_cql, _params), do: {:error, :mock_error}
  end

  describe "index/5" do
    test "returns :ok for empty fields map" do
      assert Indexer.index(nil, "ks", "post-1", %{}) == :ok
    end

    test "returns {:error, :mock_error} when repo returns error" do
      assert Indexer.index(MockFailingRepo, "ks", "post-1", %{title: "hello"}) ==
               {:error, :mock_error}
    end
  end

  describe "update/5" do
    test "returns :ok for empty fields map" do
      assert Indexer.update(nil, "ks", "post-1", %{}) == :ok
    end

    defmodule MockUpdateRepo do
      def query(_cql, _params) do
        {:ok, %{rows: [[["hello"]]]}}
      end
    end

    test "returns :ok when mock repo succeeds" do
      assert Indexer.update(MockUpdateRepo, "ks", "post-1", %{title: "hello"}) == :ok
    end

    test "returns error when terms differ and repo fails" do
      assert Indexer.update(MockFailingRepo, "ks", "post-1", %{title: "world"}) ==
               {:error, :mock_error}
    end
  end

  describe "delete/3" do
    test "returns {:error, :mock_error} when repo fails" do
      assert Indexer.delete(MockFailingRepo, "ks", "post-1") == {:error, :mock_error}
    end
  end

  describe "delete_field/4" do
    test "returns {:error, :mock_error} when repo fails" do
      assert Indexer.delete_field(MockFailingRepo, "ks", "post-1", 0) == {:error, :mock_error}
    end
  end
end
