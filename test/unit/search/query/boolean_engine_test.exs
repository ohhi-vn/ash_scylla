defmodule AshScylla.Search.Query.BooleanEngineTest do
  @moduledoc "Tests for the boolean engine."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Query.BooleanEngine

  describe "and_intersect/1" do
    test "intersects two sorted lists" do
      result =
        BooleanEngine.and_intersect([
          [{"a", 1, 1}, {"b", 1, 1}, {"c", 1, 1}],
          [{"b", 1, 1}, {"c", 1, 1}, {"d", 1, 1}]
        ])

      assert {"b", 2} in result
      assert {"c", 2} in result
      assert length(result) == 2
    end

    test "returns empty for no overlap" do
      result =
        BooleanEngine.and_intersect([
          [{"a", 1, 1}, {"b", 1, 1}],
          [{"c", 1, 1}, {"d", 1, 1}]
        ])

      assert result == []
    end

    test "intersects three lists" do
      result =
        BooleanEngine.and_intersect([
          [{"a", 1, 1}, {"b", 1, 1}, {"c", 1, 1}],
          [{"a", 1, 1}, {"b", 1, 1}, {"d", 1, 1}],
          [{"a", 1, 1}, {"b", 1, 1}, {"e", 1, 1}]
        ])

      assert {"a", 3} in result
      assert {"b", 3} in result
      assert length(result) == 2
    end

    test "handles empty input" do
      assert BooleanEngine.and_intersect([]) == []
    end

    test "handles single list" do
      result = BooleanEngine.and_intersect([[{"a", 1, 2}, {"b", 1, 1}]])
      assert {"a", 2} in result
      assert {"b", 1} in result
    end
  end

  describe "or_union/1" do
    test "unions two sorted lists" do
      result =
        BooleanEngine.or_union([
          [{"a", 1, 1}, {"b", 1, 1}],
          [{"b", 1, 1}, {"c", 1, 1}]
        ])

      assert {"a", 1} in result
      assert {"b", 2} in result
      assert {"c", 1} in result
      assert length(result) == 3
    end

    test "handles empty input" do
      assert BooleanEngine.or_union([]) == []
    end
  end

  describe "not_difference/2" do
    test "removes excluded posts" do
      result =
        BooleanEngine.not_difference(
          [{"a", 1, 1}, {"b", 1, 1}, {"c", 1, 1}],
          [{"b", 1, 1}]
        )

      assert {"a", 1} in result
      assert {"c", 1} in result
      assert length(result) == 2
    end

    test "returns all if exclude is empty" do
      result =
        BooleanEngine.not_difference(
          [{"a", 1, 1}, {"b", 1, 1}],
          []
        )

      assert length(result) == 2
    end
  end

  describe "intersect_scored/1" do
    test "intersects sorted scored lists and sums scores" do
      result =
        BooleanEngine.intersect_scored([
          [{"a", 2}, {"b", 1}, {"c", 3}],
          [{"b", 4}, {"c", 1}, {"d", 2}]
        ])

      assert result == [{"b", 5}, {"c", 4}]
    end

    test "sorts unsorted input before intersecting" do
      result =
        BooleanEngine.intersect_scored([
          [{"c", 3}, {"a", 2}, {"b", 1}],
          [{"d", 2}, {"c", 1}, {"b", 4}]
        ])

      assert result == [{"b", 5}, {"c", 4}]
    end

    test "handles empty and single lists" do
      assert BooleanEngine.intersect_scored([]) == []
      assert BooleanEngine.intersect_scored([[{"a", 1}]]) == [{"a", 1}]
      assert BooleanEngine.intersect_scored([[]]) == []
    end

    test "intersects more than two lists" do
      result =
        BooleanEngine.intersect_scored([
          [{"a", 1}, {"b", 1}],
          [{"a", 1}, {"b", 1}],
          [{"a", 1}, {"c", 1}]
        ])

      assert result == [{"a", 3}]
    end
  end

  describe "union_scored/1" do
    test "unions lists summing duplicate posts" do
      result =
        BooleanEngine.union_scored([
          [{"a", 1}, {"b", 2}],
          [{"b", 4}, {"c", 1}]
        ])

      assert result == [{"a", 1}, {"b", 6}, {"c", 1}]
    end

    test "handles empty input" do
      assert BooleanEngine.union_scored([]) == []
    end
  end
end
