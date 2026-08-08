defmodule AshScylla.Search.Query.ParserTest do
  @moduledoc "Tests for the query parser."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Query.Parser

  describe "parse/1 - simple queries" do
    test "parses single word" do
      {:ok, ast} = Parser.parse("elixir")
      assert %Parser.Group{op: :and, terms: [%Parser.Term{word: "elixir"}]} = ast
    end

    test "parses multiple words as AND" do
      {:ok, ast} = Parser.parse("learning phoenix")

      assert %Parser.Group{
               op: :and,
               terms: [%Parser.Term{word: "learning"}, %Parser.Term{word: "phoenix"}]
             } = ast
    end

    test "parses explicit AND" do
      {:ok, ast} = Parser.parse("elixir AND phoenix")

      assert %Parser.Group{
               op: :and,
               terms: [%Parser.Term{word: "elixir"}, %Parser.Term{word: "phoenix"}]
             } = ast
    end

    test "parses OR queries" do
      {:ok, ast} = Parser.parse("elixir OR phoenix")
      assert %Parser.Group{op: :or} = ast
    end

    test "parses NOT queries" do
      {:ok, ast} = Parser.parse("phoenix NOT framework")

      assert %Parser.Group{
               op: :and,
               terms: [
                 %Parser.Term{word: "phoenix"},
                 %Parser.NotExpr{term: %Parser.Term{word: "framework"}}
               ]
             } = ast
    end

    test "parses phrase queries" do
      {:ok, ast} = Parser.parse(~s("phoenix framework"))

      assert %Parser.Group{
               op: :and,
               terms: [%Parser.Phrase{words: ["phoenix", "framework"]}]
             } = ast
    end

    test "parses complex queries" do
      {:ok, ast} = Parser.parse("elixir OR phoenix NOT framework")
      assert %Parser.Group{op: :or} = ast
    end
  end

  describe "parse/1 - edge cases" do
    test "returns error for empty query" do
      assert Parser.parse("") == {:error, :empty_query}
    end

    test "returns error for whitespace-only query" do
      assert Parser.parse("   ") == {:error, :empty_query}
    end

    test "parses query with mixed case operators" do
      {:ok, ast} = Parser.parse("elixir and phoenix")
      assert %Parser.Group{op: :and} = ast
    end

    test "parses NOT with phrase" do
      {:ok, ast} = Parser.parse(~s(hello NOT "world peace"))
      assert %Parser.Group{op: :and} = ast
      assert length(ast.terms) == 2

      assert %Parser.NotExpr{term: %Parser.Phrase{words: ["world", "peace"]}} =
               Enum.at(ast.terms, 1)
    end

    test "parses explicit AND with phrases" do
      {:ok, ast} = Parser.parse(~s("hello world" AND "foo bar"))
      assert %Parser.Group{op: :and} = ast
      assert length(ast.terms) == 2
    end

    test "parses implicit AND before OR" do
      {:ok, ast} = Parser.parse("hello world OR foo")
      assert %Parser.Group{op: :or} = ast
    end

    test "parses OR with NOT inside clause" do
      {:ok, ast} = Parser.parse("hello OR world NOT foo")
      assert %Parser.Group{op: :or} = ast
    end

    test "parses multiple OR clauses" do
      {:ok, ast} = Parser.parse("a OR b OR c")
      assert %Parser.Group{op: :or} = ast
    end
  end

  describe "parse!/1" do
    test "parses valid query" do
      ast = Parser.parse!("hello world")
      assert %Parser.Group{} = ast
    end

    test "raises on empty query" do
      assert_raise ArgumentError, fn ->
        Parser.parse!("")
      end
    end
  end
end
