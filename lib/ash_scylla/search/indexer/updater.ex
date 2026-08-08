defmodule AshScylla.Search.Indexer.Updater do
  @moduledoc """
  Updates the inverted index when a document's text changes.

  Computes the diff between old and new terms:
    1. Fetches the old term set from `search_post_fields`
    2. Analyzes the new text to get new terms
    3. Removes terms present in old but not new
    4. Adds terms present in new but not old

  This avoids re-indexing unchanged terms.
  """

  alias AshScylla.Identifier

  @doc """
  Updates the index for a single field of a post.

  Takes the repo, keyspace, post_id, field number, and the new text.
  Reads the old terms from `search_post_fields`, computes the diff,
  and applies only the necessary inserts and deletes.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec update_field(
          module(),
          String.t(),
          String.t(),
          non_neg_integer(),
          [{String.t(), pos_integer()}],
          MapSet.t()
        ) :: :ok | {:error, term()}
  def update_field(repo, keyspace, post_id, field, new_terms, old_term_set) do
    new_term_set =
      new_terms
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    to_remove = MapSet.difference(old_term_set, new_term_set)
    to_add = MapSet.difference(new_term_set, old_term_set)

    add_entries =
      new_terms
      |> Enum.filter(fn {term, _} -> MapSet.member?(to_add, term) end)

    case maybe_delete_terms(repo, keyspace, post_id, field, to_remove) do
      :ok -> maybe_insert_terms(repo, keyspace, post_id, field, add_entries)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches the stored term set for a post field from `search_post_fields`.

  Returns an empty `MapSet` if no terms are found.
  """
  @spec fetch_old_terms(module(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, MapSet.t()} | {:error, term()}
  def fetch_old_terms(repo, keyspace, post_id, field) do
    AshScylla.Search.Storage.fetch_terms(repo, keyspace, post_id, field)
  end

  defp maybe_delete_terms(repo, keyspace, post_id, field, to_remove) do
    if MapSet.size(to_remove) == 0 do
      :ok
    else
      ks = Identifier.quote_name(keyspace)
      table = Identifier.quote_name("search_post_terms")

      Enum.reduce_while(to_remove, :ok, fn term, :ok ->
        shard = AshScylla.Search.Storage.shard_for(term)
        escaped = String.replace(term, "'", "''")

        query =
          "DELETE FROM #{ks}.#{table} WHERE term = '#{escaped}' AND shard = #{shard} AND post_id = #{post_id} AND field = #{field}"

        case repo.query(query, []) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp maybe_insert_terms(_repo, _keyspace, _post_id, _field, []) do
    :ok
  end

  defp maybe_insert_terms(repo, keyspace, post_id, field, add_entries) do
    ks = Identifier.quote_name(keyspace)
    table_terms = Identifier.quote_name("search_post_terms")
    table_fields = Identifier.quote_name("search_post_fields")

    inserts =
      Enum.map_join(add_entries, ";", fn {term, tf} ->
        shard = AshScylla.Search.Storage.shard_for(term)
        escaped = String.replace(term, "'", "''")

        "INSERT INTO #{ks}.#{table_terms} (term, shard, post_id, field, tf) " <>
          "VALUES ('#{escaped}', #{shard}, #{post_id}, #{field}, #{tf})"
      end)

    all_terms_set =
      add_entries
      |> Enum.map_join(", ", fn {term, _} ->
        "'#{String.replace(term, "'", "''")}'"
      end)

    update_fields =
      "UPDATE #{ks}.#{table_fields} SET terms = terms + {#{all_terms_set}} " <>
        "WHERE post_id = #{post_id} AND field = #{field}"

    cql = "BEGIN UNLOGGED BATCH\n#{inserts};\n#{update_fields};\nAPPLY BATCH;"

    case repo.query(cql, []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
