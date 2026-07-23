defmodule AshScylla.Search.Analyzer.StemmerTest do
  @moduledoc "Tests for the Porter stemmer."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Analyzer.Stemmer

  describe "stem/1" do
    test "stems plurals" do
      assert Stemmer.stem("cats") == "cat"
    end

    test "stems -ing" do
      assert Stemmer.stem("running") == "run"
      assert Stemmer.stem("learning") == "learn"
    end

    test "stems -ed" do
      assert Stemmer.stem("jumped") == "jump"
    end

    test "handles -ies" do
      assert Stemmer.stem("ponies") == "poni"
    end

    test "handles -sses" do
      assert Stemmer.stem("caresses") == "caress"
    end

    test "stems -ly" do
      assert Stemmer.stem("easily") == "easili"
    end

    test "handles -ation" do
      assert Stemmer.stem("relational") == "relat"
    end

    test "returns short words unchanged" do
      assert Stemmer.stem("go") == "go"
      assert Stemmer.stem("be") == "be"
    end

    test "returns already-stemmed words unchanged" do
      assert Stemmer.stem("elixir") == "elixir"
      assert Stemmer.stem("phoenix") == "phoenix"
    end

    test "handles -ness" do
      assert Stemmer.stem("happiness") == "happi"
    end
  end

  describe "stem_all/1" do
    test "stems and deduplicates" do
      result = Stemmer.stem_all(["running", "runs", "runner", "cats", "cat"])
      assert "run" in result
      assert "cat" in result
      assert length(result) <= 3
    end
  end
end
