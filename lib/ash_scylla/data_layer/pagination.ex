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
  Token-based pagination support for AshScylla.

  ScyllaDB/Cassandra doesn't support OFFSET natively. Instead, it uses
  Xandra's native paging state mechanism for efficient pagination.

  ## Token-Based Pagination

  When `pagination :token` is set in the ash_scylla DSL, queries use
  Xandra's built-in paging state to efficiently page through results
  without OFFSET.

  ## Usage

      # First page
      {:ok, records, next_page_token} =
        AshScylla.DataLayer.Pagination.fetch_page(repo, table, filters, nil, 10)

      # Subsequent pages
      {:ok, records, next_page_token} =
        AshScylla.DataLayer.Pagination.fetch_page(repo, table, filters, page_token, 10)

  ## Page Token Format

  Page tokens are opaque binaries returned by Xandra's paging_state.
  They should be treated as opaque by callers and only passed back
  to fetch the next page.
  """

  require Logger

  alias AshScylla.DataLayer.QueryBuilder

  @default_page_size 50
  @max_page_size 1000

  @type page_result :: {:ok, [term()], String.t() | nil} | {:error, term()}
  @type page_token :: String.t() | nil

  @doc """
  Fetches a page of results using Xandra's native paging state.

  ## Parameters

  - `repo` - The Ecto repo module
  - `table` - The table name
  - `filters` - Filter list for WHERE clause
  - `page_token` - Opaque page token from previous page (nil for first page)
  - `page_size` - Number of results per page (default: 50, max: 1000)

  ## Returns

  `{:ok, records, next_page_token}` where `next_page_token` is nil
  when there are no more pages.
  """
  @spec fetch_page(module(), String.t(), list(), page_token(), pos_integer()) :: page_result()
  def fetch_page(repo, table, filters, page_token, page_size \\ @default_page_size) do
    page_size = min(page_size, @max_page_size)

    Logger.debug(
      "AshScylla: Fetching page from #{table} with page_size=#{page_size}, " <>
        "has_token=#{not is_nil(page_token)}"
    )

    {where_clause, params} = build_where_clause(filters)

    query =
      [
        "SELECT * FROM ",
        table,
        if(where_clause != "", do: [" WHERE ", where_clause], else: []),
        " LIMIT ?"
      ]
      |> IO.iodata_to_binary()

    params = params ++ [page_size]

    opts =
      if page_token do
        page_state = Base.decode64!(page_token)
        [page_size: page_size, page_state: page_state]
      else
        [page_size: page_size]
      end

    case repo.query(query, params, opts) do
      {:ok, %{rows: rows, paging_state: nil}} ->
        records = Enum.map(rows, &normalize_record/1)
        {:ok, records, nil}

      {:ok, %{rows: rows, paging_state: next_state}} when is_binary(next_state) ->
        records = Enum.map(rows, &normalize_record/1)
        next_token = Base.encode64(next_state)
        {:ok, records, next_token}

      {:ok, %{rows: rows}} ->
        records = Enum.map(rows, &normalize_record/1)
        {:ok, records, nil}

      {:error, error} ->
        Logger.error("AshScylla: Pagination query failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Builds a CQL query string with LIMIT for pagination.

  Returns `{query, params}` suitable for `repo.query/3`.
  """
  @spec build_paginated_query(String.t(), list(), pos_integer()) :: {String.t(), list()}
  def build_paginated_query(table, filters, page_size) do
    build_paginated_query(table, filters, nil, page_size)
  end

  @doc """
  Builds a CQL query string with LIMIT for pagination, with optional page token.

  When `page_token` is non-nil, adds a `token() > ?` condition to the WHERE clause.
  Returns `{query, params}` suitable for `repo.query/3`.
  """
  @spec build_paginated_query(String.t(), list(), page_token(), pos_integer()) ::
          {String.t(), list()}
  def build_paginated_query(table, filters, page_token, page_size) do
    page_size = min(page_size, @max_page_size)
    {where_clause, params} = build_where_clause(filters)

    where_clause =
      if is_nil(page_token) do
        where_clause
      else
        token_clause = "token() > ?"
        if where_clause != "", do: where_clause <> " AND " <> token_clause, else: token_clause
      end

    params =
      if is_nil(page_token) do
        params
      else
        params ++ [page_token]
      end

    query =
      [
        "SELECT * FROM ",
        table,
        if(where_clause != "", do: [" WHERE ", where_clause], else: []),
        " LIMIT ?"
      ]
      |> IO.iodata_to_binary()

    {query, params ++ [page_size]}
  end

  @doc """
  Encodes a paging state binary to an opaque page token string.
  """
  @spec encode_page_token(binary()) :: String.t()
  def encode_page_token(paging_state) when is_binary(paging_state) do
    Base.encode64(paging_state)
  end

  @doc """
  Decodes a page token string back to a paging state binary.
  """
  @spec decode_page_token(String.t()) :: binary()
  def decode_page_token(page_token) when is_binary(page_token) do
    Base.decode64!(page_token)
  end

  @doc """
  Returns the default page size.
  """
  @spec default_page_size() :: pos_integer()
  def default_page_size, do: @default_page_size

  @doc """
  Returns the maximum allowed page size.
  """
  @spec max_page_size() :: pos_integer()
  def max_page_size, do: @max_page_size

  @spec build_where_clause(list()) :: {String.t(), list()}
  defp build_where_clause([]), do: {"", []}

  defp build_where_clause(filters) do
    filter_structs =
      Enum.map(filters, fn
        %{operator: _, left: _, right: _} = f ->
          f

        {key, value} when is_atom(key) ->
          %{operator: :eq, left: %{name: key}, right: %{value: value}}

        %{name: key, value: value} ->
          %{operator: :eq, left: %{name: key}, right: %{value: value}}
      end)

    QueryBuilder.build_where_clause(filter_structs)
  end

  @spec normalize_record(term()) :: map()
  defp normalize_record(record) when is_map(record), do: record
  defp normalize_record(record) when is_list(record), do: Map.new(record)
  defp normalize_record(_), do: %{}
end
