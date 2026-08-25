defmodule AshScylla.Search.Query.PlannerCoverageTest do
  @moduledoc "Covers planner error propagation, repo result shapes, and OR-group edge cases."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Query.{Parser, Planner}

  # Fails the lookup for one specific term; pure function so it is safe
  # inside the planner's Task.async_stream workers.
  defmodule Src2SelectiveRepo do
    def query(_cql, ["boom"]), do: {:error, :term_boom}
    def query(_cql, _params), do: {:ok, %{rows: [["p1", 1]]}}
  end

  defmodule Src2IndexRepo do
    def query(_cql, ["phoenix"]), do: {:ok, %{rows: [["p1", 2]]}}
    def query(_cql, _params), do: {:ok, %{rows: []}}
  end

  # Generic repo (no query_all/3) returning an %Xandra.Page{} instead of rows.
  defmodule Src2XandraPageRepo do
    def query(_cql, _params), do: {:ok, %Xandra.Page{content: [["p1", 2], ["p2", 1]]}}
  end

  defmodule Src2JunkRowsRepo do
    def query(_cql, _params), do: {:ok, %{rows: ["junk", ["p1", 2], ["p9"]]}}
  end

  describe "plan/4 - OR groups" do
    test "propagates a branch error out of the top-level OR group" do
      {:ok, ast} = Parser.parse("phoenix OR boom")
      assert Planner.plan(Src2SelectiveRepo, "ks", ast) == {:error, :term_boom}
    end

    test "bare leaves inside a hand-built OR group are treated as one-term AND groups" do
      ast = %Parser.Group{terms: [%Parser.Term{word: "phoenix"}], op: :or}
      assert Planner.plan(Src2IndexRepo, "ks", ast) == {:ok, %{"p1" => [{"phoenix", 2}]}}
    end

    test "OR group with no branches returns empty results" do
      ast = %Parser.Group{terms: [], op: :or}
      assert Planner.plan(Src2IndexRepo, "ks", ast) == {:ok, %{}}
    end

    test "OR group with a single branch returns that branch unchanged" do
      ast = %Parser.Group{
        terms: [%Parser.Group{terms: [%Parser.Term{word: "phoenix"}], op: :and}],
        op: :or
      }

      assert Planner.plan(Src2IndexRepo, "ks", ast) == {:ok, %{"p1" => [{"phoenix", 2}]}}
    end
  end

  describe "plan/4 - repo result shapes" do
    test "reads postings from an %Xandra.Page{} when the repo lacks query_all/3" do
      {:ok, ast} = Parser.parse("phoenix")

      assert Planner.plan(Src2XandraPageRepo, "ks", ast) ==
               {:ok, %{"p1" => [{"phoenix", 2}], "p2" => [{"phoenix", 1}]}}
    end

    test "skips malformed posting rows" do
      {:ok, ast} = Parser.parse("phoenix")
      assert Planner.plan(Src2JunkRowsRepo, "ks", ast) == {:ok, %{"p1" => [{"phoenix", 2}]}}
    end
  end
end
