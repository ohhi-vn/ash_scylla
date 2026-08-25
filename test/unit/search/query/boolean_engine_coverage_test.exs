defmodule AshScylla.Search.Query.BooleanEngineCoverageTest do
  @moduledoc "Covers the two-pointer advance when list A's post sorts before list B's."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Query.BooleanEngine

  test "intersection advances list A on non-matching smaller post" do
    assert BooleanEngine.intersect_scored([[{"a", 1}, {"b", 2}], [{"b", 3}, {"c", 4}]]) ==
             [{"b", 5}]
  end

  test "intersection advancing only through A yields empty result" do
    assert BooleanEngine.intersect_scored([
             [{"a", 1}, {"c", 1}],
             [{"b", 1}, {"d", 1}]
           ]) == []
  end
end
