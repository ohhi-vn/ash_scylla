defmodule AshScylla.Search.Analyzer.TokenizerTest do
  @moduledoc "Tests for the Unicode-aware tokenizer."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Analyzer.Tokenizer

  describe "tokenize/1" do
    test "splits on whitespace" do
      assert Tokenizer.tokenize("Learning Elixir Phoenix Framework") ==
               ["Learning", "Elixir", "Phoenix", "Framework"]
    end

    test "strips punctuation" do
      assert Tokenizer.tokenize("Phoenix,Framework!  test-case") ==
               ["Phoenix", "Framework", "test", "case"]
    end

    test "handles unicode characters" do
      assert Tokenizer.tokenize("hello 世界 测试") == ["hello", "世界", "测试"]
    end

    test "keeps underscores within words" do
      assert Tokenizer.tokenize("hello_world test_case") == ["hello_world", "test_case"]
    end

    test "returns empty list for empty string" do
      assert Tokenizer.tokenize("") == []
    end

    test "returns empty list for punctuation only" do
      assert Tokenizer.tokenize("!!! ??? ---") == []
    end
  end

  describe "tokenize/2 with options" do
    test "filters by min_length" do
      assert Tokenizer.tokenize("a bb ccc dddd", min_length: 3) == ["ccc", "dddd"]
    end
  end

  describe "tokenize_fields/1" do
    test "merges tokens from multiple fields" do
      result = Tokenizer.tokenize_fields(%{
        title: "Learning Elixir",
        body: "Phoenix Framework"
      })

      assert Enum.sort(result) ==
               Enum.sort(["Learning", "Elixir", "Phoenix", "Framework"])
    end
  end
end
