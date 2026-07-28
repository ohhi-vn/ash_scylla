defmodule AshScylla.Search.Query.PlannerTest do
  use ExUnit.Case, async: true

  alias AshScylla.Search.Query.Parser
  alias AshScylla.Search.Query.Planner

  defmodule MockLookupRepo do
    def query(_cql, _params) do
      {:ok, %{rows: []}}
    end
  end

  defmodule MockFailingRepo do
    def query(_cql, _params) do
      {:error, :lookup_failed}
    end
  end

  describe "plan/4" do
    test "returns {:ok, _} for single term with empty results" do
      {:ok, ast} = Parser.parse("hello")
      assert Planner.plan(MockLookupRepo, "ks", ast) == {:ok, %{}}
    end

    test "returns {:error, :lookup_failed} when repo lookup fails" do
      {:ok, ast} = Parser.parse("hello")
      assert Planner.plan(MockFailingRepo, "ks", ast) == {:error, :lookup_failed}
    end

    test "returns {:ok, _} for AND group with empty results" do
      {:ok, ast} = Parser.parse("hello world")
      assert Planner.plan(MockLookupRepo, "ks", ast) == {:ok, %{}}
    end

    test "returns {:error, :lookup_failed} for AND group when repo fails" do
      {:ok, ast} = Parser.parse("hello world")
      assert Planner.plan(MockFailingRepo, "ks", ast) == {:error, :lookup_failed}
    end

    test "returns {:ok, _} for single term OR query" do
      ast = %Parser.Group{
        terms: [%Parser.Term{word: "hello"}, %Parser.Term{word: "world"}],
        op: :or
      }

      assert Planner.plan(MockLookupRepo, "ks", ast) == {:ok, %{}}
    end

    test "handles phrase queries" do
      {:ok, ast} = Parser.parse(~s("hello world"))
      assert Planner.plan(MockLookupRepo, "ks", ast) == {:ok, %{}}
    end

    test "handles not expression with empty results" do
      {:ok, ast} = Parser.parse("-exclude")
      assert Planner.plan(MockLookupRepo, "ks", ast) == {:ok, %{}}
    end
  end
end
