defmodule AshScylla.Search.Query.ParserCoverageTest do
  @moduledoc "Covers OR-clause parsing paths (phrases, NOT phrases, AND tokens)."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Query.Parser

  describe "parse/1 - phrases inside OR clauses" do
    test "parses phrase inside OR clause" do
      {:ok, ast} = Parser.parse(~s(a OR "world peace"))

      assert [
               %Parser.Group{terms: [%Parser.Term{word: "a"}], op: :and},
               %Parser.Group{terms: [%Parser.Phrase{words: ["world", "peace"]}], op: :and}
             ] = ast.terms
    end

    test "parses NOT phrase inside OR clause" do
      {:ok, ast} = Parser.parse(~s(a OR x NOT "world peace"))

      assert [
               %Parser.Group{terms: [%Parser.Term{word: "a"}]},
               %Parser.Group{
                 terms: [
                   %Parser.Term{word: "x"},
                   %Parser.NotExpr{term: %Parser.Phrase{words: ["world", "peace"]}}
                 ]
               }
             ] = ast.terms
    end

    test "AND token inside OR clause joins following words" do
      {:ok, ast} = Parser.parse("a OR b AND c")

      assert [
               %Parser.Group{terms: [%Parser.Term{word: "a"}], op: :and},
               %Parser.Group{
                 terms: [%Parser.Term{word: "b"}, %Parser.Term{word: "c"}],
                 op: :and
               }
             ] = ast.terms
    end
  end
end
