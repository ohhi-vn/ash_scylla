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
