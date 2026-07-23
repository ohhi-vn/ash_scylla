defmodule AshScylla.Search.Indexer.Deleter do
  @moduledoc """
  Removes a document from the inverted index.

  Deletes all term entries for a post from both `search_post_terms`
  and `search_post_fields`.
  """

  alias AshScylla.Identifier

  @doc """
  Deletes all index entries for a post across all fields.

  First reads the terms from `search_post_fields` so we know which
  partition keys to target for deletion in `search_post_terms`.
  Then deletes from both tables.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec delete(module(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(repo, keyspace, post_id) do
    with {:ok, all_terms} <- fetch_all_terms(repo, keyspace, post_id),
         :ok <- delete_terms(repo, keyspace, post_id, all_terms),
         :ok <- delete_fields(repo, keyspace, post_id) do
      :ok
    end
  end

  @doc """
  Deletes all index entries for a specific field of a post.
  """
  @spec delete_field(module(), String.t(), String.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  def delete_field(repo, keyspace, post_id, field) do
    with {:ok, terms} <- fetch_field_terms(repo, keyspace, post_id, field),
         :ok <- delete_terms(repo, keyspace, post_id, terms, field) do
      :ok
    end
  end

  defp fetch_all_terms(repo, keyspace, post_id) do
    ks = Identifier.quote_name(keyspace)
    table = Identifier.quote_name("search_post_fields")

    cql = "SELECT terms FROM #{ks}.#{table} WHERE post_id = #{post_id}"

    case repo.query(cql, []) do
      {:ok, %{rows: []}} -> {:ok, MapSet.new()}
      {:ok, %{rows: rows}} ->
        all_terms =
          rows
          |> Enum.flat_map(fn [terms] -> terms end)
          |> MapSet.new()

        {:ok, all_terms}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_field_terms(repo, keyspace, post_id, field) do
    ks = Identifier.quote_name(keyspace)
    table = Identifier.quote_name("search_post_fields")

    cql =
      "SELECT terms FROM #{ks}.#{table} WHERE post_id = #{post_id} AND field = #{field}"

    case repo.query(cql, []) do
      {:ok, %{rows: []}} -> {:ok, MapSet.new()}
      {:ok, %{rows: [[terms]]}} -> {:ok, MapSet.new(terms)}
      {:ok, %{rows: rows}} ->
        all_terms = Enum.flat_map(rows, fn [terms] -> terms end)
        {:ok, MapSet.new(all_terms)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_terms(repo, keyspace, post_id, to_remove, field \\ nil) do
    if MapSet.size(to_remove) == 0 do
      :ok
    else
    ks = Identifier.quote_name(keyspace)
    table = Identifier.quote_name("search_post_terms")

    field_clause = if field, do: " AND field = #{field}", else: ""

    Enum.reduce_while(to_remove, :ok, fn term, :ok ->
      shard = AshScylla.Search.Storage.shard_for(term)
      escaped = String.replace(term, "'", "''")
      query = "DELETE FROM #{ks}.#{table} WHERE term = '#{escaped}' AND shard = #{shard} AND post_id = #{post_id}#{field_clause}"

      case repo.query(query, []) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    end
  end

  defp delete_fields(repo, keyspace, post_id) do
    ks = Identifier.quote_name(keyspace)
    table = Identifier.quote_name("search_post_fields")

    cql = "DELETE FROM #{ks}.#{table} WHERE post_id = #{post_id}"

    case repo.query(cql, []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
