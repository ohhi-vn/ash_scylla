defmodule AshScylla.Search.Analyzer.NormalizerTest do
  @moduledoc "Tests for the text normalizer."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Analyzer.Normalizer

  describe "normalize_term/1" do
    test "lowercases text" do
      assert Normalizer.normalize_term("Phoenix") == "phoenix"
    end

    test "strips surrounding punctuation" do
      assert Normalizer.normalize_term("!!!Phoenix!!!") == "phoenix"
    end

    test "strips leading and trailing whitespace" do
      assert Normalizer.normalize_term("  elixir  ") == "elixir"
    end

    test "returns nil for punctuation-only strings" do
      assert Normalizer.normalize_term("!!!") == nil
    end

    test "returns nil for whitespace-only strings" do
      assert Normalizer.normalize_term("   ") == nil
    end

    test "returns nil for empty string" do
      assert Normalizer.normalize_term("") == nil
    end

    test "preserves inner punctuation" do
      assert Normalizer.normalize_term("hello-world") == "hello-world"
    end
  end

  describe "normalize_terms/1" do
    test "filters out nil results" do
      assert Normalizer.normalize_terms(["Phoenix", "!!!", "  ", "Elixir"]) ==
               ["phoenix", "elixir"]
    end

    test "does not deduplicate (caller handles that)" do
      assert Normalizer.normalize_terms(["Phoenix", "phoenix", "PHOENIX"]) ==
               ["phoenix", "phoenix", "phoenix"]
    end
  end
end
