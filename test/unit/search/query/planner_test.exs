defmodule AshScylla.Search.Query.PlannerTest do
  @moduledoc "Tests for the query planner."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Query.Parser
  alias AshScylla.Search.Query.Planner

  # Serves rows for a fixed in-memory index, keyed by the bound term param.
  # Rows use Xandra shape: [post_id, field, tf].
  defmodule IndexRepo do
    @postings %{
      "phoenix" => [["p1", 2], ["p2", 1]],
      "framework" => [["p2", 1], ["p3", 4]],
      "elixir" => [["p3", 1]]
    }

    def query(cql, [term]) do
      assert cql =~ ~s(shard IN ()
      assert cql =~ "term = ?"
      assert cql =~ "SELECT post_id, tf"
      {:ok, %{rows: Map.get(@postings, term, [])}}
    end
  end

  defmodule EmptyRepo do
    def query(_cql, _params), do: {:ok, %{rows: []}}
  end

  defmodule FailingRepo do
    def query(_cql, _params), do: {:error, :boom}
  end

  # Forwards every executed CQL statement to the calling test process.
  defmodule CapturingRepo do
    def query(cql, _params) do
      send(self(), {:captured_cql, cql})
      {:ok, %{rows: []}}
    end
  end

  # Real AshScylla.Repo modules expose query_all/3; the planner must prefer it
  # so posting lists larger than one CQL page are never truncated.
  defmodule PagingRepo do
    def query(cql, params), do: send(self(), {:single_page_cql, cql, params})

    def query_all(cql, params, _opts) do
      send(self(), {:query_all_cql, cql, params})
      {:ok, %{rows: [["p1", 3]]}}
    end
  end

  describe "plan/4 - boolean semantics" do
    test "single term returns per-term scores" do
      {:ok, ast} = Parser.parse("phoenix")

      assert Planner.plan(IndexRepo, "ks", ast) ==
               {:ok, %{"p1" => [{"phoenix", 2}], "p2" => [{"phoenix", 1}]}}
    end

    test "prefers query_all/3 when the repo supports full paging" do
      {:ok, ast} = Parser.parse("phoenix")
      assert Planner.plan(PagingRepo, "ks", ast) == {:ok, %{"p1" => [{"phoenix", 3}]}}
      assert_received {:query_all_cql, cql, ["phoenix"]}
      assert cql =~ "SELECT post_id, tf"
      refute_received {:single_page_cql, _, _}
    end

    test "implicit AND intersects posting lists" do
      {:ok, ast} = Parser.parse("phoenix framework")

      assert Planner.plan(IndexRepo, "ks", ast) ==
               {:ok, %{"p2" => [{"framework", 1}, {"phoenix", 1}]}}
    end

    test "explicit AND behaves like implicit AND" do
      {:ok, implicit} = Parser.parse("phoenix framework")
      {:ok, explicit} = Parser.parse("phoenix AND framework")
      assert Planner.plan(IndexRepo, "ks", implicit) == Planner.plan(IndexRepo, "ks", explicit)
    end

    test "OR unions branches" do
      {:ok, ast} = Parser.parse("phoenix OR elixir")

      assert Planner.plan(IndexRepo, "ks", ast) ==
               {:ok,
                %{"p1" => [{"phoenix", 2}], "p2" => [{"phoenix", 1}], "p3" => [{"elixir", 1}]}}
    end

    test "NOT excludes matching documents" do
      {:ok, ast} = Parser.parse("phoenix NOT framework")
      assert Planner.plan(IndexRepo, "ks", ast) == {:ok, %{"p1" => [{"phoenix", 2}]}}
    end

    test "minus prefix excludes matching documents" do
      {:ok, not_ast} = Parser.parse("phoenix NOT framework")
      {:ok, minus_ast} = Parser.parse("phoenix -framework")
      assert Planner.plan(IndexRepo, "ks", not_ast) == Planner.plan(IndexRepo, "ks", minus_ast)
    end

    test "NOT inside an OR branch only affects that branch" do
      {:ok, ast} = Parser.parse("elixir OR phoenix NOT framework")

      assert Planner.plan(IndexRepo, "ks", ast) ==
               {:ok, %{"p1" => [{"phoenix", 2}], "p3" => [{"elixir", 1}]}}
    end

    test "phrase matches documents containing all words (unordered AND)" do
      {:ok, ast} = Parser.parse(~s("phoenix framework"))

      assert Planner.plan(IndexRepo, "ks", ast) ==
               {:ok, %{"p2" => [{"framework", 1}, {"phoenix", 1}]}}
    end

    test "phrase with stop word reduces to remaining words" do
      {:ok, ast} = Parser.parse(~s("the phoenix"))

      assert Planner.plan(IndexRepo, "ks", ast) ==
               {:ok, %{"p1" => [{"phoenix", 2}], "p2" => [{"phoenix", 1}]}}
    end
  end

  describe "plan/4 - analysis edge cases" do
    test "stop word alongside positive terms is dropped, not constraining" do
      {:ok, ast} = Parser.parse("the phoenix")

      assert Planner.plan(IndexRepo, "ks", ast) ==
               {:ok, %{"p1" => [{"phoenix", 2}], "p2" => [{"phoenix", 1}]}}
    end

    test "unknown positive term constrains AND to empty result" do
      {:ok, ast} = Parser.parse("phoenix unknownword")
      assert Planner.plan(IndexRepo, "ks", ast) == {:ok, %{}}
    end

    test "pure negative query returns :missing_positive_term" do
      {:ok, ast} = Parser.parse("-framework")
      assert Planner.plan(IndexRepo, "ks", ast) == {:error, :missing_positive_term}
    end

    test "stop-word-only query returns :missing_positive_term" do
      {:ok, ast} = Parser.parse("the")
      assert Planner.plan(EmptyRepo, "ks", ast) == {:error, :missing_positive_term}
    end

    test "empty results for single term against empty index" do
      {:ok, ast} = Parser.parse("hello")
      assert Planner.plan(EmptyRepo, "ks", ast) == {:ok, %{}}
    end
  end

  describe "plan/4 - options and errors" do
    test "propagates repo errors" do
      {:ok, ast} = Parser.parse("hello")
      assert Planner.plan(FailingRepo, "ks", ast) == {:error, :boom}
    end

    test "rejects invalid num_shards" do
      {:ok, ast} = Parser.parse("hello")
      assert Planner.plan(EmptyRepo, "ks", ast, num_shards: 0) == {:error, :invalid_num_shards}
      assert Planner.plan(EmptyRepo, "ks", ast, num_shards: -3) == {:error, :invalid_num_shards}
    end

    test "respects custom num_shards in CQL" do
      {:ok, ast} = Parser.parse("hello")

      assert Planner.plan(CapturingRepo, "ks", ast, num_shards: 4) == {:ok, %{}}
      assert_received {:captured_cql, cql}
      assert cql =~ "shard IN (0, 1, 2, 3)"
      refute cql =~ "shard IN (0, 1, 2, 3,"
    end

    test "issues one query per analyzed term" do
      {:ok, ast} = Parser.parse("phoenix framework")

      assert Planner.plan(IndexRepo, "ks", ast) ==
               {:ok, %{"p2" => [{"framework", 1}, {"phoenix", 1}]}}
    end
  end
end
