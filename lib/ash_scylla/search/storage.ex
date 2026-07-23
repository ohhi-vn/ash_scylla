defmodule AshScylla.Search.Storage do
  @moduledoc """
  CQL schema definitions for the inverted index tables used by the search engine.

  Provides functions to create and drop the required tables for the inverted
  index. The tables are:

    * `search_post_terms` — maps terms to post IDs with term frequency (TF)
    * `search_post_fields` — stores the analyzed field text for update/delete diffing

  ## Usage

      AshScylla.Search.Storage.create_tables(MyApp.Repo, "my_keyspace")
      AshScylla.Search.Storage.drop_tables(MyApp.Repo, "my_keyspace")
  """

  alias AshScylla.Identifier

  @doc """
  Returns the CQL statement to create the `search_post_terms` table.

  This is the primary inverted index table. Each row maps a term to a post_id
  with term frequency for ranking.

  Partition key: `(term, shard)` to avoid hotspot partitions for common terms.
  Clustering key: `post_id` for ordered retrieval.
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
      field tinyint,
      tf smallint,
      PRIMARY KEY ((term, shard), post_id, field)
    )
    """
  end

  @doc """
  Returns the CQL statement to create the `search_post_fields` table.

  Stores the raw analyzed text per field for each post. Used during updates
  to diff old vs new terms and compute additions/removals.
  """
  @spec create_post_fields_cql(String.t()) :: String.t()
  def create_post_fields_cql(keyspace) do
    ks = Identifier.quote_name(keyspace)
    table = Identifier.quote_name("search_post_fields")

    """
    CREATE TABLE IF NOT EXISTS #{ks}.#{table} (
      post_id uuid,
      field tinyint,
      terms set<text>,
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
end
