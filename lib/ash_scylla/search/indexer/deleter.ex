defmodule AshScylla.Search.Indexer.Deleter do
  @moduledoc """
  Removes a document from the inverted index.

  Deletes all posting rows for a post from `search_post_terms` and its field
  maps from `search_post_fields`.
  """

  alias AshScylla.Identifier
  alias AshScylla.Search.Storage

  @doc """
  Deletes all index entries for a post across all fields.

  Reads the stored field maps so we know which term partitions to target,
  deletes the postings, then deletes the stored field rows.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec delete(module(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(repo, keyspace, post_id) do
    with {:ok, uuid} <- Identifier.validate_uuid(post_id),
         {:ok, field_maps} <- Storage.fetch_field_maps(repo, keyspace, uuid) do
      terms = Storage.sum_field_maps(field_maps) |> Map.keys()

      case delete_postings(repo, keyspace, uuid, terms) do
        :ok -> delete_all_field_rows(repo, keyspace, uuid)
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Removes a single field from the index for a document.

  Document-level postings are recomputed: terms that only this field
  contributed are deleted; shared terms have their totals lowered. The
  field's stored map row is removed.
  """
  @spec delete_field(module(), String.t(), String.t(), atom() | String.t()) ::
          :ok | {:error, term()}
  def delete_field(repo, keyspace, post_id, field_name) do
    field = to_string(field_name)

    with {:ok, uuid} <- Identifier.validate_uuid(post_id),
         {:ok, field_maps} <- Storage.fetch_field_maps(repo, keyspace, uuid) do
      field_map = Map.get(field_maps, field, %{})
      remaining = Map.delete(field_maps, field)
      new_totals = Storage.sum_field_maps(remaining)

      # Every term this field contributed is either fully removed or its
      # document-level total lowers to the sum of the remaining fields.
      {deletes, upserts} =
        Enum.reduce(field_map, {[], []}, fn {term, _tf}, {dels, ups} ->
          case Map.get(new_totals, term, 0) do
            0 -> {[term | dels], ups}
            new_total -> {dels, [{term, new_total} | ups]}
          end
        end)

      with :ok <- apply_field_removal(repo, keyspace, uuid, deletes, upserts) do
        delete_one_field_row(repo, keyspace, uuid, field)
      end
    end
  end

  defp apply_field_removal(repo, keyspace, uuid, deletes, upserts) do
    with :ok <- delete_postings(repo, keyspace, uuid, deletes) do
      upsert_postings(repo, keyspace, uuid, upserts)
    end
  end

  @doc false
  # Shared with the updater: deletes document-level posting rows for the
  # given terms with bound parameters.
  @spec delete_postings(module(), String.t(), String.t(), [String.t()]) ::
          :ok | {:error, term()}
  def delete_postings(_repo, _keyspace, _uuid, []), do: :ok

  def delete_postings(repo, keyspace, uuid, terms) do
    ks = Identifier.quote_name(keyspace)
    table = Identifier.quote_name("search_post_terms")

    Enum.reduce_while(terms, :ok, fn term, :ok ->
      shard = Storage.shard_for(term)

      query = "DELETE FROM #{ks}.#{table} WHERE term = ? AND shard = #{shard} AND post_id = ?"

      case repo.query(query, [term, uuid]) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_postings(_repo, _keyspace, _uuid, []), do: :ok

  defp upsert_postings(repo, keyspace, uuid, upserts) do
    alias AshScylla.Search.Indexer.Builder

    with {:ok, cql} <- Builder.build_postings_batch_cql(keyspace, uuid, Enum.sort(upserts)) do
      case repo.query(cql, []) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp delete_all_field_rows(repo, keyspace, uuid) do
    ks = Identifier.quote_name(keyspace)
    table = Identifier.quote_name("search_post_fields")

    case repo.query("DELETE FROM #{ks}.#{table} WHERE post_id = ?", [uuid]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_one_field_row(repo, keyspace, uuid, field) do
    ks = Identifier.quote_name(keyspace)
    table = Identifier.quote_name("search_post_fields")

    case repo.query("DELETE FROM #{ks}.#{table} WHERE post_id = ? AND field = ?", [uuid, field]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
