defmodule AshScylla.Search.Query.BooleanEngine do
  @moduledoc """
  Boolean operations on posting lists.

  Implements efficient set operations using a two-pointer merge algorithm
  with O(n + m) complexity — identical to how Lucene performs intersections
  and unions.

  Supports:
    * AND — intersection of posting lists
    * OR — union of posting lists
    * NOT — difference of posting lists
  """

  @type posting_list :: [{String.t(), non_neg_integer(), non_neg_integer()}]
  @type scored_post :: {String.t(), non_neg_integer()}
  @type scored_list :: [scored_post()]

  @doc """
  Computes the AND intersection of multiple posting lists.

  Uses a two-pointer merge algorithm for each pair of lists.

  ## Example

      iex> BooleanEngine.and_intersect([
      ...>   [{"a", 1, 0}, {"b", 1, 1}, {"c", 1, 2}],
      ...>   [{"b", 1, 0}, {"c", 1, 1}, {"d", 1, 2}]
      ...> ])
      [{"b", 1}, {"c", 3}]
  """
  @spec and_intersect([posting_list()]) :: scored_list()
  def and_intersect(lists) when is_list(lists) do
    lists
    |> Enum.map(&to_scored/1)
    |> intersect_scored()
  end

  @doc """
  Computes the AND intersection of multiple scored posting lists
  (`{post_id, tf}` pairs sorted by `post_id`).

  Uses a two-pointer merge algorithm for each pair of lists, summing the
  scores of matching posts.

  ## Example

      iex> BooleanEngine.intersect_scored([
      ...>   [{"a", 2}, {"b", 1}, {"c", 3}],
      ...>   [{"b", 4}, {"c", 1}, {"d", 2}]
      ...> ])
      [{"b", 5}, {"c", 4}]
  """
  @spec intersect_scored([scored_list()]) :: scored_list()
  def intersect_scored([]), do: []

  def intersect_scored([first | rest]) do
    Enum.reduce(rest, first, &intersect_pairs/2)
  end

  @doc """
  Computes the OR union of multiple posting lists.

  ## Example

      iex> BooleanEngine.or_union([
      ...>   [{"a", 1, 0}, {"b", 1, 1}],
      ...>   [{"b", 1, 0}, {"c", 1, 1}]
      ...> ])
      [{"a", 1}, {"b", 1}, {"c", 1}]
  """
  @spec or_union([posting_list()]) :: scored_list()
  def or_union(lists) when is_list(lists) do
    lists
    |> Enum.map(&to_scored/1)
    |> union_scored()
  end

  @doc """
  Computes the OR union of multiple scored posting lists
  (`{post_id, tf}` pairs). Scores of posts appearing in several lists
  are summed. The result is sorted by `post_id`.

  ## Example

      iex> BooleanEngine.union_scored([
      ...>   [{"a", 1}, {"b", 2}],
      ...>   [{"b", 4}, {"c", 1}]
      ...> ])
      [{"a", 1}, {"b", 6}, {"c", 1}]
  """
  @spec union_scored([scored_list()]) :: scored_list()
  def union_scored([]), do: []

  def union_scored(lists) do
    # Single pass over each list into one map (O(total)) — avoids the
    # flatten/group_by pipeline that dominated large OR queries. Tuple sort
    # orders by post_id first, matching the documented output contract.
    lists
    |> Enum.reduce(%{}, fn list, acc ->
      Enum.reduce(list, acc, fn {post_id, tf}, acc ->
        Map.update(acc, post_id, tf, &(&1 + tf))
      end)
    end)
    |> Map.to_list()
    |> Enum.sort()
  end

  @doc """
  Computes the difference: posts in `include` that are NOT in `exclude`.

  ## Example

      iex> BooleanEngine.not_difference(
      ...>   [{"a", 1, 0}, {"b", 1, 1}, {"c", 1, 2}],
      ...>   [{"b", 1, 0}]
      ...> )
      [{"a", 1}, {"c", 1}]
  """
  @spec not_difference(posting_list(), posting_list()) :: [{String.t(), non_neg_integer()}]
  def not_difference(include, exclude) do
    exclude_set = MapSet.new(exclude, fn {post_id, _, _} -> post_id end)

    include
    |> Enum.reject(fn {post_id, _, _} -> MapSet.member?(exclude_set, post_id) end)
    |> Enum.map(fn {post_id, _, tf} -> {post_id, tf} end)
  end

  defp to_scored(list), do: Enum.map(list, fn {post_id, _field, tf} -> {post_id, tf} end)

  defp intersect_pairs(list_a, list_b) do
    intersect_sorted(Enum.sort_by(list_a, &elem(&1, 0)), Enum.sort_by(list_b, &elem(&1, 0)), [])
  end

  defp intersect_sorted([], _list_b, acc), do: Enum.reverse(acc)
  defp intersect_sorted(_list_a, [], acc), do: Enum.reverse(acc)

  defp intersect_sorted([{post_a, tf_a} | rest_a] = a, [{post_b, tf_b} | rest_b] = b, acc) do
    cond do
      post_a == post_b ->
        intersect_sorted(rest_a, rest_b, [{post_a, tf_a + tf_b} | acc])

      post_a < post_b ->
        intersect_sorted(rest_a, b, acc)

      true ->
        intersect_sorted(a, rest_b, acc)
    end
  end
end
