defmodule AshScylla.Search.Indexer.UpdaterTest do
  use ExUnit.Case, async: true

  alias AshScylla.Search.Indexer.Updater

  defmodule MockRepo do
    def query(_cql, _params) do
      {:ok, %{rows: [[["test"]]]}}
    end
  end

  defmodule MockFailingRepo do
    def query(_cql, _params), do: {:error, :mock_error}
  end

  describe "update_field/6" do
    test "returns :ok when old and new terms are identical" do
      old_terms = MapSet.new(["hello", "world"])
      new_terms = [{"hello", 1}, {"world", 2}]
      assert Updater.update_field(nil, "ks", "post-1", 0, new_terms, old_terms) == :ok
    end

    test "returns :ok when old_terms is empty and new_terms is empty" do
      assert Updater.update_field(nil, "ks", "post-1", 0, [], MapSet.new()) == :ok
    end

    test "returns {:error, ...} when there are new terms to add and repo fails" do
      old_terms = MapSet.new()
      new_terms = [{"hello", 1}]
      assert Updater.update_field(MockFailingRepo, "ks", "post-1", 0, new_terms, old_terms) ==
               {:error, :mock_error}
    end

    test "returns {:error, ...} when there are terms to remove and repo fails" do
      old_terms = MapSet.new(["hello"])
      new_terms = []
      assert Updater.update_field(MockFailingRepo, "ks", "post-1", 0, new_terms, old_terms) ==
               {:error, :mock_error}
    end

    test "returns {:error, ...} when both add and remove needed and repo fails" do
      old_terms = MapSet.new(["a", "b"])
      new_terms = [{"b", 1}, {"c", 2}]
      assert Updater.update_field(MockFailingRepo, "ks", "post-1", 0, new_terms, old_terms) ==
               {:error, :mock_error}
    end
  end

  describe "fetch_old_terms/4" do
    test "returns {:ok, term_set} when mock repo has terms" do
      assert Updater.fetch_old_terms(MockRepo, "ks", "post-1", 0) == {:ok, MapSet.new(["test"])}
    end

    test "returns {:error, ...} when mock repo fails" do
      assert Updater.fetch_old_terms(MockFailingRepo, "ks", "post-1", 0) ==
               {:error, :mock_error}
    end
  end
end
