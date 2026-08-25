defmodule AshScylla.Search.Storage do
  @moduledoc """
  CQL schema definitions for the inverted index tables used by the search engine.

  Provides functions to create and drop the required tables for the inverted
  index. The tables are:

    * `search_post_terms` — inverted index mapping `(term, shard, post_id)` to
      the term's total frequency within the document (summed across fields)
    * `search_post_fields` — per-field term/frequency maps used to compute
      diff-based updates

  Postings are stored at **document level**: one row per `(term, post_id)`.
  Queries fetch F× fewer rows than per-field layouts (F = number of fields),
  which is the dominant cost when reading hot terms.

  ## Usage

      AshScylla.Search.Storage.create_tables(MyApp.Repo, "my_keyspace")
      AshScylla.Search.Storage.drop_tables(MyApp.Repo, "my_keyspace")
  """

  alias AshScylla.Identifier

  @doc """
  Returns the CQL statement to create the `search_post_terms` table.

  This is the primary inverted index table. Each row maps a term to a post_id
  with the term's total frequency in that document.

  Partition key: `(term, shard)` to avoid hotspot partitions for common terms.
  Clustering key: `post_id`.
  """
  @spec create_post_terms_cql(String.t()) :: String.t()
  def create_post_terms_cql(keyspace) do
    ks = Identifier.quote_name(keyspace)
    table = Identifier.quote_name("search_post_terms")

    """
    CREATE TABLE IF NOT EXISTS #{ks}.#{table} (
      term text,
      shard smallint,
      post_id uuid,
      tf smallint,
      PRIMARY KEY ((term, shard), post_id)
    )
    """
  end

  @doc """
  Returns the CQL statement to create the `search_post_fields` table.

  Stores the analyzed terms with their frequencies for each post field. Used
  during updates to diff old vs new content and recompute document-level totals.
  """
  @spec create_post_fields_cql(String.t()) :: String.t()
  def create_post_fields_cql(keyspace) do
    ks = Identifier.quote_name(keyspace)
    table = Identifier.quote_name("search_post_fields")

    """
    CREATE TABLE IF NOT EXISTS #{ks}.#{table} (
      post_id uuid,
      field text,
      terms map<text, smallint>,
      PRIMARY KEY (post_id, field)
    )
    """
  end

  @doc """
  Creates all search engine tables in the given keyspace.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec create_tables(module(), String.t()) :: :ok | {:error, term()}
  def create_tables(repo, keyspace) do
    statements = [
      create_post_terms_cql(keyspace),
      create_post_fields_cql(keyspace)
    ]

    Enum.reduce_while(statements, :ok, fn cql, :ok ->
      case repo.query(cql, []) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Drops all search engine tables from the given keyspace.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec drop_tables(module(), String.t()) :: :ok | {:error, term()}
  def drop_tables(repo, keyspace) do
    ks = Identifier.quote_name(keyspace)

    statements = [
      "DROP TABLE IF EXISTS #{ks}.#{Identifier.quote_name("search_post_terms")}",
      "DROP TABLE IF EXISTS #{ks}.#{Identifier.quote_name("search_post_fields")}"
    ]

    Enum.reduce_while(statements, :ok, fn cql, :ok ->
      case repo.query(cql, []) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Computes the shard number for a given term.

  Uses `:erlang.phash2/2` to distribute terms across the configured number
  of shards. This prevents hotspot partitions for high-frequency terms.
  """
  @spec shard_for(String.t(), non_neg_integer()) :: non_neg_integer()
  def shard_for(term, num_shards \\ 16) when num_shards > 0 do
    rem(:erlang.phash2(term, num_shards), num_shards)
  end

  @doc """
  Fetches every stored field map for a post from `search_post_fields`.

  Returns `%{"field_name" => %{"term" => tf}}`. Empty map if the post has no
  indexed fields.
  """
  @spec fetch_field_maps(module(), String.t(), String.t()) ::
          {:ok, %{String.t() => %{String.t() => pos_integer()}}} | {:error, term()}
  def fetch_field_maps(repo, keyspace, post_id) do
    with {:ok, uuid} <- Identifier.validate_uuid(post_id) do
      ks = Identifier.quote_name(keyspace)
      table = Identifier.quote_name("search_post_fields")

      case repo.query("SELECT field, terms FROM #{ks}.#{table} WHERE post_id = ?", [uuid]) do
        {:ok, %{rows: rows}} ->
          {:ok, rows_to_field_maps(rows)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp rows_to_field_maps(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      case row do
        [field, terms] when is_binary(field) ->
          Map.put(acc, field, normalize_term_map(terms))

        _ ->
          acc
      end
    end)
  end

  defp normalize_term_map(terms) when is_map(terms),
    do: Map.new(terms, fn {k, v} -> {to_string(k), v} end)

  defp normalize_term_map(_other), do: %{}

  @doc false
  # Field map values may be `%{term => tf}` maps (as fetched from the DB) or
  # `[{term, tf}]` lists (as produced by the analyzer).
  @spec sum_field_maps(%{String.t() => %{String.t() => pos_integer()} | list()}) ::
          %{String.t() => pos_integer()}
  def sum_field_maps(field_maps) do
    Enum.reduce(field_maps, %{}, fn {_field, terms}, acc ->
      Map.merge(acc, to_term_map(terms), fn _term, tf_a, tf_b -> tf_a + tf_b end)
    end)
  end

  defp to_term_map(terms) when is_map(terms), do: terms
  defp to_term_map(terms) when is_list(terms), do: Map.new(terms)
  defp to_term_map(_other), do: %{}
end
