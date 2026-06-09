# Copyright [2024] AshScylla Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule AshScylla.DataLayer.FilterValidator do
  @moduledoc """
  Validates that filter columns are queryable in ScyllaDB/Cassandra.

  ScyllaDB/Cassandra requires that WHERE clause columns are either:
  - Part of the primary key
  - Have a secondary index defined

  Filtering on non-indexed columns would require `ALLOW FILTERING`, which
  is an anti-pattern that causes full cluster scans. This module catches
  such issues at query-build time and provides actionable error messages.
  """

  require Logger

  alias Ash.Resource.Info
  alias AshScylla.DataLayer.Dsl

  @doc """
  Validates that all filter columns on a resource are queryable.

  Returns `:ok` if all filters are on primary key columns or indexed columns.
  Raises `AshScylla.Error` with an actionable message if a filter would
  require `ALLOW FILTERING`.

  ## Parameters

  - `resource` - The Ash resource module
  - `filters` - List of Ash filter expressions

  ## Examples

      AshScylla.DataLayer.FilterValidator.validate_filters(MyApp.User, filters)
      # => :ok

      AshScylla.DataLayer.FilterValidator.validate_filters(MyApp.User, [{:non_indexed_col, :eq, "value"}])
      # => raises AshScylla.Error with suggestion to add secondary_index
  """
  @spec validate_filters(module(), list()) :: :ok | no_return()
  def validate_filters(resource, filters) do
    pk_columns = get_primary_key_columns(resource)
    indexed_columns = get_indexed_columns(resource)
    allowed_columns = MapSet.new(pk_columns ++ indexed_columns)

    filter_columns = extract_all_filter_columns(filters)

    non_queryable =
      filter_columns
      |> Enum.reject(fn col -> MapSet.member?(allowed_columns, col) end)
      |> Enum.uniq()

    case non_queryable do
      [] ->
        :ok

      cols ->
        col_names = Enum.map_join(cols, ", ", &"#{&1}")
        pk_names = Enum.map_join(pk_columns, ", ", &"#{&1}")
        idx_names = Enum.map_join(indexed_columns, ", ", &"#{&1}")

        raise AshScylla.Error,
          message:
            "Filter on column(s) [#{col_names}] requires a secondary index. " <>
              "These columns are not part of the primary key [#{pk_names}] " <>
              "and do not have secondary indexes [#{idx_names}]. " <>
              "Add `secondary_index :#{hd(cols)}` to your ash_scylla block, " <>
              "or create a materialized view for this query pattern."
    end
  end

  @doc """
  Returns the list of columns that are safe to filter on for a resource.
  """
  @spec queryable_columns(module()) :: [atom()]
  def queryable_columns(resource) do
    get_primary_key_columns(resource) ++ get_indexed_columns(resource)
  end

  defp get_primary_key_columns(resource) do
    if Info.resource?(resource) do
      resource
      |> Info.attributes()
      |> Enum.filter(& &1.primary_key?)
      |> Enum.map(& &1.name)
    else
      [:id]
    end
  end

  defp get_indexed_columns(resource) do
    resource
    |> Dsl.secondary_indexes()
    |> Enum.flat_map(fn idx -> idx.columns end)
    |> Enum.uniq()
  end

  defp extract_all_filter_columns(filters) do
    filters
    |> List.flatten()
    |> Enum.flat_map(&extract_columns_from_filter/1)
    |> Enum.uniq()
  end

  defp extract_columns_from_filter(%{left: %{name: name}}) when is_atom(name), do: [name]
  defp extract_columns_from_filter(%{expression: expr}), do: extract_all_filter_columns([expr])

  defp extract_columns_from_filter(%{left: left, right: right}),
    do: extract_all_filter_columns([left, right])

  defp extract_columns_from_filter(%{name: name}) when is_atom(name), do: [name]
  defp extract_columns_from_filter(_), do: []
end
