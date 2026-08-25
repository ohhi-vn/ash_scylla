defmodule AshScylla.Search.Query.ParserDanglingTest do
  @moduledoc """
  The parser must tolerate dangling boolean operators instead of crashing.
  """

  use ExUnit.Case, async: true

  alias AshScylla.Search.Query.Parser

  describe "dangling operators" do
    test "a trailing NOT is dropped" do
      assert {:ok, ast} = Parser.parse("elixir NOT")
      assert {:ok, expected} = Parser.parse("elixir")
      assert ast == expected
    end

    test "a trailing NOT before AND is dropped" do
      assert {:ok, ast} = Parser.parse("hello NOT AND world")

      assert %Parser.Group{
               terms: [%Parser.Term{word: "hello"}, %Parser.Term{word: "world"}],
               op: :and
             } = ast
    end

    test "a dangling NOT inside an OR branch is dropped" do
      assert {:ok, ast} = Parser.parse("elixir OR phoenix NOT")
      assert %{op: :or} = ast

      assert {:ok, expected} = Parser.parse("elixir OR phoenix")
      assert ast == expected
    end

    test "parse!/1 does not raise on dangling operators" do
      assert %Parser.Group{} = Parser.parse!("a NOT OR b NOT")
    end
  end
end
