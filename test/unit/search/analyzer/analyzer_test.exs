defmodule AshScylla.Search.AnalyzerTest do
  @moduledoc "Tests for the analyzer pipeline coordinator."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Analyzer

  describe "analyze/1" do
    test "tokenizes, normalizes, and stems" do
      result = Analyzer.analyze("Running Cats are Learning Elixir")
      result_map = Map.new(result)

      assert Map.has_key?(result_map, "run")
      assert Map.has_key?(result_map, "cat")
      assert Map.has_key?(result_map, "learn")
      assert Map.has_key?(result_map, "elixir")
    end

    test "removes stop words" do
      result = Analyzer.analyze("The quick brown fox is running very fast")
      terms = Enum.map(result, &elem(&1, 0))
      refute "the" in terms
      refute "is" in terms
      refute "very" in terms
    end

    test "counts term frequencies" do
      result = Analyzer.analyze("Phoenix Phoenix Elixir")
      assert {"phoenix", 2} in result
      assert {"elixir", 1} in result
    end

    test "respects :stem option" do
      with_stem = Analyzer.analyze("running", stem: true)
      without_stem = Analyzer.analyze("running", stem: false)

      assert {"run", 1} in with_stem
      assert {"running", 1} in without_stem
    end

    test "respects :remove_stop_words option" do
      with = Analyzer.analyze("the elixir", remove_stop_words: true)
      without = Analyzer.analyze("the elixir", remove_stop_words: false)

      terms_with = Enum.map(with, &elem(&1, 0))
      terms_without = Enum.map(without, &elem(&1, 0))

      refute "the" in terms_with
      assert "the" in terms_without
    end
  end

  describe "analyze_fields/1" do
    test "merges term frequencies across fields" do
      result = Analyzer.analyze_fields(%{
        title: "Elixir Phoenix",
        body: "Phoenix is great for Elixir"
      })

      assert {"elixir", 2} in result
      assert {"phoenix", 2} in result
      assert {"great", 1} in result
    end
  end

  describe "analyze_query/1" do
    test "analyzes query terms for searching" do
      result = Analyzer.analyze_query("learning phoenix framework")
      assert result == ["learn", "phoenix", "framework"]
    end

    test "removes stop words from query" do
      result = Analyzer.analyze_query("the elixir is awesome")
      assert "the" not in result
      assert "is" not in result
      assert "elixir" in result
    end

    test "respects :stem option" do
      assert Analyzer.analyze_query("running", stem: false) == ["running"]
      assert Analyzer.analyze_query("running", stem: true) == ["run"]
    end
  end
end
