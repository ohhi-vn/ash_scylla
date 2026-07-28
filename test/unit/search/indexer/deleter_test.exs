defmodule AshScylla.Search.Indexer.DeleterTest do
  use ExUnit.Case, async: true

  alias AshScylla.Search.Indexer.Deleter

  defmodule MockRepo do
    def query(_cql, _params), do: {:error, :mock_error}
  end

  describe "delete/3" do
    test "returns {:error, :mock_error} when mock repo returns error" do
      assert Deleter.delete(MockRepo, "ks", "post-1") == {:error, :mock_error}
    end
  end

  describe "delete_field/4" do
    test "returns {:error, :mock_error} when mock repo returns error" do
      assert Deleter.delete_field(MockRepo, "ks", "post-1", 0) == {:error, :mock_error}
    end
  end

  describe "delete/3 success paths" do
    defmodule MockSuccessRepo do
      def query(_cql, _params), do: {:ok, %{rows: []}}
    end

    defmodule MockWithTermsRepo do
      def query(cql, _params) do
        cond do
          String.contains?(cql, "SELECT terms") -> {:ok, %{rows: [[["hello", "world"]]]}}
          true -> {:ok, %{}}
        end
      end
    end

    defmodule MockFailingDeleteFieldRepo do
      def query(cql, _params) do
        cond do
          String.contains?(cql, "SELECT terms") -> {:ok, %{rows: [[["term1"]]]}}
          String.contains?(cql, "DELETE FROM") and String.contains?(cql, "search_post_fields") ->
            {:error, :field_delete_error}
          true -> {:ok, %{}}
        end
      end
    end

    test "returns :ok when repo has no terms" do
      assert Deleter.delete(MockSuccessRepo, "ks", "post-1") == :ok
    end

    test "returns :ok when repo has terms and deletes succeed" do
      assert Deleter.delete(MockWithTermsRepo, "ks", "post-1") == :ok
    end

    test "returns error when delete_fields fails" do
      assert Deleter.delete(MockFailingDeleteFieldRepo, "ks", "post-1") ==
               {:error, :field_delete_error}
    end
  end

  describe "delete_field/4 success paths" do
    defmodule MockFieldSuccessRepo do
      def query(cql, _params) do
        cond do
          String.contains?(cql, "SELECT terms") -> {:ok, %{rows: []}}
          true -> {:ok, %{}}
        end
      end
    end

    defmodule MockFieldEmptyRepo do
      def query(_cql, _params), do: {:ok, %{rows: []}}
    end

    defmodule MockFieldFailingFetchRepo do
      def query(_cql, _params), do: {:error, :fetch_error}
    end

    defmodule MockFieldWithTermsRepo do
      def query(cql, _params) do
        cond do
          String.contains?(cql, "SELECT terms") -> {:ok, %{rows: [[["alpha", "beta"]]]}}
          true -> {:ok, %{}}
        end
      end
    end

    test "returns :ok when field has no terms (deletes succeed)" do
      assert Deleter.delete_field(MockFieldSuccessRepo, "ks", "post-1", 0) == :ok
    end

    test "returns :ok when field has no terms" do
      assert Deleter.delete_field(MockFieldEmptyRepo, "ks", "post-1", 0) == :ok
    end

    test "returns error when fetching field terms fails" do
      assert Deleter.delete_field(MockFieldFailingFetchRepo, "ks", "post-1", 0) ==
               {:error, :fetch_error}
    end

    test "returns :ok when field has terms and deletes succeed" do
      assert Deleter.delete_field(MockFieldWithTermsRepo, "ks", "post-1", 0) == :ok
    end
  end
end
