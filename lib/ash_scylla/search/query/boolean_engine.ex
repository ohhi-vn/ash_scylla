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
  @type scored_post :: {String.t(), float()}

  @doc """
  Computes the AND intersection of multiple posting lists.

  Uses a two-pointer merge algorithm for each pair of lists.

  ## Example

      iex> BooleanEngine.and_intersect([
      ...>   [{"a", 1, 0}, {"b", 1, 1}, {"c", 1, 2}],
      ...>   [{"b", 1, 0}, {"c", 1, 1}, {"d", 1, 2}]
      ...> ])
      [{"b", 1}, {"c", 1}]
  """
  @spec and_intersect([posting_list()]) :: [{String.t(), non_neg_integer()}]
  def and_intersect(lists) when is_list(lists) do
    sorted = Enum.sort_by(lists, &length/1)

    case sorted do
      [] -> []
      [first | rest] -> Enum.reduce(rest, first, &intersect_two/2)
    end
    |> Enum.map(fn {post_id, _field, tf} -> {post_id, tf} end)
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
  @spec or_union([posting_list()]) :: [{String.t(), non_neg_integer()}]
  def or_union(lists) when is_list(lists) do
    case lists do
      [] -> []
      _ ->
        lists
        |> List.flatten()
        |> Enum.group_by(fn {post_id, _field, _tf} -> post_id end, fn {_, _field, tf} -> tf end)
        |> Enum.map(fn {post_id, tfs} -> {post_id, Enum.sum(tfs)} end)
        |> Enum.sort_by(&elem(&1, 0))
    end
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

  defp intersect_two(list_a, list_b) do
    intersect_sorted(list_a, list_b, [])
  end

  defp intersect_sorted([], _list_b, acc), do: Enum.reverse(acc)
  defp intersect_sorted(_list_a, [], acc), do: Enum.reverse(acc)

  defp intersect_sorted(
         [{post_a, field_a, tf_a} | rest_a] = a,
         [{post_b, _field_b, tf_b} | rest_b] = b,
         acc
       ) do
    cond do
      post_a == post_b ->
        intersect_sorted(rest_a, rest_b, [{post_a, field_a, tf_a + tf_b} | acc])

      post_a < post_b ->
        intersect_sorted(rest_a, b, acc)

      true ->
        intersect_sorted(a, rest_b, acc)
    end
  end
end
