defmodule AshScylla.Search.Indexer.Updater do
  @moduledoc """
  Applies aggregate-level index diffs for a document.

  Postings are stored at document level (one row per term with total
  frequency), while `search_post_fields` keeps per-field maps. An update:

    1. Computes the new merged document totals from the stored field maps and
       the newly analyzed fields
    2. Deletes posting rows whose total dropped to zero
    3. Upserts posting rows whose total changed
    4. Rewrites the `search_post_fields` rows of every updated field

  This keeps multi-field documents correct even when a term is shared across
  fields (removing it from one field only lowers the total).
  """

  alias AshScylla.Identifier
  alias AshScylla.Search.Indexer.Builder
  alias AshScylla.Search.Indexer.Deleter

  @doc """
  Applies a precomputed diff between merged old and new document totals.

    * `upserts` — `[{"term", new_total}]` postings that are new or changed
    * `deletes` — `["term"]` postings removed entirely
    * `field_maps` — `%{"field" => [{term, tf}]}` analyzed maps of the fields
      being updated; fields with an empty list have their stored row deleted

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec apply_diff(
          module(),
          String.t(),
          String.t(),
          [{String.t(), pos_integer()}],
          [String.t()],
          %{String.t() => [{String.t(), pos_integer()}]}
        ) :: :ok | {:error, term()}
  def apply_diff(repo, keyspace, post_id, upserts, deletes, field_maps) do
    with {:ok, uuid} <- Identifier.validate_uuid(post_id) do
      with :ok <- delete_postings(repo, keyspace, uuid, deletes),
           :ok <- upsert_postings(repo, keyspace, uuid, upserts) do
        write_fields(repo, keyspace, uuid, field_maps)
      end
    end
  end

  defp delete_postings(repo, keyspace, uuid, terms) do
    Deleter.delete_postings(repo, keyspace, uuid, terms)
  end

  defp upsert_postings(_repo, _keyspace, _uuid, []), do: :ok

  defp upsert_postings(repo, keyspace, uuid, upserts) do
    with {:ok, cql} <- Builder.build_postings_batch_cql(keyspace, uuid, Enum.sort(upserts)) do
      case repo.query(cql, []) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Full-map overwrite per updated field: additions, frequency changes, and
  # removals are all reflected, so stale entries can never accumulate.
  defp write_fields(repo, keyspace, uuid, field_maps) do
    ks = Identifier.quote_name(keyspace)
    table = Identifier.quote_name("search_post_fields")

    Enum.reduce_while(field_maps, :ok, fn {field, terms}, :ok ->
      result =
        if terms == [] do
          repo.query("DELETE FROM #{ks}.#{table} WHERE post_id = ? AND field = ?", [
            uuid,
            field
          ])
        else
          map_literal =
            terms
            |> Map.new(fn {term, tf} -> {term, tf} end)
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.map_join(", ", fn {term, tf} -> "#{Builder.cql_string(term)}: #{tf}" end)

          cql =
            "UPDATE #{ks}.#{table} SET terms = {#{map_literal}} WHERE post_id = ? AND field = ?"

          repo.query(cql, [uuid, field])
        end

      case result do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
