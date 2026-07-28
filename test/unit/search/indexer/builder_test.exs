defmodule AshScylla.Search.Indexer.BuilderTest do
  use ExUnit.Case, async: true

  alias AshScylla.Search.Indexer.Builder

  defmodule MockRepo do
    def query(_cql, _params), do: {:error, :mock_error}
  end

  describe "index/5" do
    test "returns {:error, :mock_error} when mock repo returns error" do
      assert Builder.index(MockRepo, "ks", "post-1", 0, [{"hello", 1}]) ==
               {:error, :mock_error}
    end

    test "returns {:error, :mock_error} when terms have tf" do
      assert Builder.index(MockRepo, "ks", "post-1", 0, [{"elixir", 2}, {"phoenix", 1}]) ==
               {:error, :mock_error}
    end
  end

  describe "index_fields/4" do
    test "returns :ok for empty map" do
      assert Builder.index_fields(nil, "ks", "post-1", %{}) == :ok
    end

    test "returns {:error, :mock_error} when mock repo returns error" do
      assert Builder.index_fields(MockRepo, "ks", "post-1", %{0 => [{"hello", 1}]}) ==
               {:error, :mock_error}
    end
  end
end
