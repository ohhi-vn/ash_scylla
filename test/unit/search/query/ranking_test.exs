defmodule AshScylla.Search.Query.RankingTest do
  @moduledoc "Tests for the ranking engine."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Query.Ranking

  describe "rank/2 with :tf strategy" do
    test "ranks by total term frequency" do
      results = [
        {"post1", [{"phoenix", 3}, {"elixir", 5}]},
        {"post2", [{"phoenix", 1}]},
        {"post3", [{"phoenix", 6}, {"elixir", 5}]}
      ]

      ranked = Ranking.rank(results, strategy: :tf)

      assert length(ranked) == 3

      [{id1, score1, _}, {_id2, score2, _}, {_id3, score3, _}] = ranked
      assert id1 == "post3"
      assert score1 == 11.0
      assert score1 >= score2
      assert score2 >= score3
    end

    test "handles empty input" do
      assert Ranking.rank([], strategy: :tf) == []
    end
  end

  describe "rank/2 with :tfidf strategy" do
    test "applies IDF weighting" do
      results = [
        {"post1", [{"phoenix", 3}]},
        {"post2", [{"phoenix", 1}]}
      ]

      ranked = Ranking.rank(results,
        strategy: :tfidf,
        total_docs: 100,
        doc_freqs: %{"phoenix" => 10}
      )

      assert length(ranked) == 2
      [{_, score1, _}, {_, score2, _}] = ranked
      assert score1 > score2
    end
  end

  describe "rank/2 with :bm25 strategy" do
    test "applies BM25 scoring" do
      results = [
        {"post1", [{"phoenix", 3}]},
        {"post2", [{"phoenix", 1}]}
      ]

      ranked = Ranking.rank(results,
        strategy: :bm25,
        total_docs: 100,
        doc_freqs: %{"phoenix" => 10},
        avg_doc_length: 5.0
      )

      assert length(ranked) == 2
      [{_, score1, _}, {_, score2, _}] = ranked
      assert score1 > score2
    end
  end

  describe "idf/2" do
    test "computes IDF correctly" do
      assert Ranking.idf(100, 10) > 0.0
      assert Ranking.idf(100, 100) < Ranking.idf(100, 10)
    end

    test "returns 0 for edge cases" do
      assert Ranking.idf(0, 10) == 0.0
      assert Ranking.idf(100, 0) == 0.0
    end
  end
end
