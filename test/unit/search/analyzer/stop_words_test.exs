defmodule AshScylla.Search.Analyzer.StopWordsTest do
  @moduledoc "Tests for the stop words filter."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Analyzer.StopWords

  describe "stop_word?/1" do
    test "identifies common stop words" do
      assert StopWords.stop_word?("the")
      assert StopWords.stop_word?("is")
      assert StopWords.stop_word?("of")
      assert StopWords.stop_word?("a")
      assert StopWords.stop_word?("and")
    end

    test "returns false for meaningful words" do
      refute StopWords.stop_word?("elixir")
      refute StopWords.stop_word?("phoenix")
      refute StopWords.stop_word?("framework")
      refute StopWords.stop_word?("learning")
    end
  end

  describe "filter/1" do
    test "removes stop words from list" do
      input = ["the", "quick", "brown", "fox", "is", "very", "fast"]
      result = StopWords.filter(input)
      assert "the" not in result
      assert "is" not in result
      assert "very" not in result
      assert "quick" in result
      assert "brown" in result
      assert "fox" in result
      assert "fast" in result
    end

    test "returns empty list if all are stop words" do
      assert StopWords.filter(["the", "a", "is", "of"]) == []
    end

    test "preserves non-stop words" do
      assert StopWords.filter(["elixir", "phoenix"]) == ["elixir", "phoenix"]
    end
  end
end
