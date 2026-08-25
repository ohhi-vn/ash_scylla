defmodule AshScylla.Search.IndexerTest do
  use ExUnit.Case, async: true

  alias AshScylla.Search.Indexer

  @uuid "550e8400-e29b-41d4-a716-446655440000"

  defmodule FailingRepo do
    def query(_cql, _params), do: {:error, :mock_error}
  end

  defmodule CaptureRepo do
    def query(cql, params) do
      send(self(), {:cql, {cql, params}})
      {:ok, %{rows: []}}
    end
  end

  describe "index/5" do
    test "rejects invalid post_id" do
      assert {:error, _} = Indexer.index(FailingRepo, "ks", "post-1", %{title: "hello"})
    end

    test "returns :ok for empty fields map" do
      assert Indexer.index(nil, "ks", @uuid, %{}) == :ok
    end

    test "writes one batch with aggregated postings and per-field maps" do
      assert Indexer.index(CaptureRepo, "ks", @uuid, %{
               title: "elixir elixir phoenix",
               body: "elixir guide"
             }) == :ok

      assert_received {:cql, {cql, _}}
      # single round trip for the whole document
      refute_received {:cql, _}

      # doc-level totals: elixir = 2 + 1, phoenix = 1, guid = 1
      assert cql =~ ~r/'elixir', \d+, #{@uuid}, 3/
      assert cql =~ ~r/'phoenix', \d+, #{@uuid}, 1/
      assert cql =~ ~r/'guid', \d+, #{@uuid}, 1/
      assert cql =~ "'title'"
      assert cql =~ "'body'"
    end

    test "returns {:error, :mock_error} when repo returns error" do
      assert Indexer.index(FailingRepo, "ks", @uuid, %{title: "hello"}) == {:error, :mock_error}
    end
  end

  describe "update/5" do
    test "rejects invalid post_id" do
      assert {:error, _} = Indexer.update(FailingRepo, "ks", "post-1", %{title: "hello"})
    end

    test "returns :ok for empty fields map" do
      assert Indexer.update(nil, "ks", @uuid, %{}) == :ok
    end

    test "recomputes document totals across fields on partial update" do
      defmodule StoredRepo do
        def query("SELECT field, terms" <> _, _params),
          do: {:ok, %{rows: [["title", %{"elixir" => 2}], ["body", %{"elixir" => 1}]]}}

        def query(cql, params), do: CaptureRepo.query(cql, params)
      end

      # body rewritten without "elixir": doc total drops from 3 to title's 2.
      assert Indexer.update(StoredRepo, "ks", @uuid, %{body: "guide"}) == :ok

      assert_received {:cql, {batch_cql, []}}
      assert batch_cql =~ ~r/'elixir', \d+, #{@uuid}, 2/
      assert batch_cql =~ ~r/'guid', \d+, #{@uuid}, 1/
      assert_received {:cql, {fields_cql, [@uuid, "body"]}}
      assert fields_cql =~ "'guid': 1"
    end

    test "deletes postings when the last contribution disappears" do
      defmodule SingleFieldRepo do
        def query("SELECT field, terms" <> _, _params),
          do: {:ok, %{rows: [["body", %{"gone" => 2}]]}}

        def query(cql, params), do: CaptureRepo.query(cql, params)
      end

      assert Indexer.update(SingleFieldRepo, "ks", @uuid, %{body: "fresh"}) == :ok

      assert_received {:cql, {delete_cql, ["gone", @uuid]}}
      assert delete_cql =~ ~r/DELETE FROM .*search_post_terms/

      assert_received {:cql, {batch_cql, []}}
      assert batch_cql =~ ~r/'fresh', \d+, #{@uuid}, 1/
    end

    test "no-op when nothing changed" do
      defmodule SameRepo do
        def query("SELECT field, terms" <> _, _params),
          do: {:ok, %{rows: [["title", %{"hello" => 1}]]}}

        def query(_cql, _params), do: {:ok, %{rows: []}}
      end

      assert Indexer.update(SameRepo, "ks", @uuid, %{title: "hello"}) == :ok
      refute_received {:cql, _}
    end

    test "returns error when repo fails" do
      assert Indexer.update(FailingRepo, "ks", @uuid, %{title: "world"}) == {:error, :mock_error}
    end
  end

  describe "delete/3 and delete_field/4" do
    test "delete returns error when repo fetch fails" do
      assert {:error, :mock_error} = Indexer.delete(FailingRepo, "ks", @uuid)
    end

    test "delete_field returns error when repo fetch fails" do
      assert {:error, :mock_error} = Indexer.delete_field(FailingRepo, "ks", @uuid, "title")
    end
  end
end
