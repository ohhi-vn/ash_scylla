defmodule AshScylla.Search.Analyzer.CoverageTest do
  @moduledoc "Covers analyze_query/2 with stop-word filtering disabled."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Analyzer

  test "analyze_query/2 keeps stop words when :remove_stop_words is false" do
    terms = Analyzer.analyze_query("the phoenix running", remove_stop_words: false)
    assert "the" in terms
    assert "phoenix" in terms
  end
end
