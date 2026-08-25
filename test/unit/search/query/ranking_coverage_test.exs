defmodule AshScylla.Search.Query.RankingCoverageTest do
  @moduledoc "Covers rank/1 defaults and unknown-strategy fallback."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Query.Ranking

  @results [
    {"post1", [{"phoenix", 3}]},
    {"post2", [{"phoenix", 1}]}
  ]

  test "rank/1 defaults to tf scoring" do
    assert Ranking.rank(@results) ==
             [{"post1", 3.0, [{"phoenix", 3}]}, {"post2", 1.0, [{"phoenix", 1}]}]
  end

  test "unknown strategy falls back to tf scoring" do
    assert Ranking.rank(@results, strategy: :bogus) == Ranking.rank(@results, strategy: :tf)
  end
end
