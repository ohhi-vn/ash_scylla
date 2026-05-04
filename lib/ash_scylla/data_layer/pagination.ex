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

defmodule AshScylla.DataLayer.Pagination do
  @moduledoc """
  Pagination support for AshScylla using ScyllaDB/Cassandra tokens.

  ScyllaDB/Cassandra doesn't support OFFSET natively.
  Instead, it uses tokens for efficient pagination.
  """

  @moduledoc since: "1.0.0"

  @doc """
  Fetches a page of results using token-based pagination.

  ## Examples:

      # First page
      {:ok, {records, next_token}} = DataLayer.Pagination.fetch_page(repo, table, %{}, nil, 10)

      # Next page using token
      {:ok, {records, next_token}} = DataLayer.Pagination.fetch_page(repo, table, %{}, token, 10)
  """
  def fetch_page(repo, table, filters, token, page_size) do
    # Build base query
    {where_clause, params} = build_where_clause(filters)

    query = "SELECT * FROM #{table}"
    query = if String.length(where_clause) > 0 do
      "#{query} WHERE #{where_clause}"
    else
      query
    end

    # Add token condition for pagination
    {query, params} = if token do
      {"#{query} AND token() > ?", params ++ [token]}
    else
      {query, params}
    end

    # Add LIMIT
    query = "#{query} LIMIT ?"
    params = params ++ [page_size]

    case repo.query(query, params) do
      {:ok, %{rows: rows, paging_state: next_token}} ->
        records = Enum.map(rows, &to_ash_record(&1, nil))
        {:ok, {records, next_token}}

      error -> error
    end
  end

  @doc """
  Builds a CQL query with token-based pagination.
  """
  def build_paginated_query(table, filters, token, page_size) do
    # Build base query
    {where_clause, params} = build_where_clause(filters)

    query = "SELECT * FROM #{table}"
    query = if String.length(where_clause) > 0 do
      "#{query} WHERE #{where_clause}"
    else
      query
    end

    # Add token condition
    {query, params} = if token do
      {"#{query} AND token() > ?", params ++ [token]}
    else
      {query, params}
    end

    # Add LIMIT
    query = "#{query} LIMIT ?"
    params = params ++ [page_size]

    {query, params}
  end

  defp build_where_clause(filters) do
    case filters do
      %{} -> {"", []}
      _ -> {"1=1", []}  # Placeholder
    end
  end

  defp to_ash_record(record, _resource) do
    # Convert record to Ash format
    case record do
      list when is_list(list) -> list
      map when is_map(map) -> map
      _ -> %{}
    end
  end
end
