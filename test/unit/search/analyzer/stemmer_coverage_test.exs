defmodule AshScylla.Search.Analyzer.StemmerCoverageTest do
  @moduledoc "Covers remaining stemmer rule branches."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Analyzer.Stemmer

  describe "stem/1 - step 1b" do
    test "-eed kept unchanged when the stem has no consonant-vowel transition" do
      assert Stemmer.stem("freed") == "freed"
    end

    test "-eed with measurable stem doubles the e before later steps trim it" do
      assert Stemmer.stem("proceed") == "proce"
    end

    test "-bl stems get a final e" do
      assert Stemmer.stem("troubled") == "troubl"
    end

    test "-iz stems get a final e" do
      assert Stemmer.stem("sizing") == "size"
    end

    test "cvc-ending stems get a final e" do
      assert Stemmer.stem("hoped") == "hope"
    end
  end

  describe "stem/1 - step 5b and helpers" do
    test "measurable double-l endings lose the final l" do
      assert Stemmer.stem("recalling") == "recal"
    end

    test "uppercase vowels count as vowels during measurement" do
      assert Stemmer.stem("HOPping") == "HOPp"
    end

    test "one-letter stems fail the double-consonant check" do
      assert Stemmer.stem("aed") == "a"
    end

    test "two-letter stems fail the cvc check" do
      assert Stemmer.stem("hoing") == "ho"
    end
  end
end
