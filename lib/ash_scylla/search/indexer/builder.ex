defmodule AshScylla.Search.Indexer.Builder do
  @moduledoc """
  Builds the inverted index for a document.

  Takes the analyzed terms and writes them to the `search_post_terms` table
  and the raw terms set to `search_post_fields` for later diff-based updates.

  Uses `UNLOGGED BATCH` for efficient bulk writes.

  ## Usage

      Indexer.Builder.index(repo, keyspace, post_id, field_num, [
        {"phoenix", 2},
        {"elixir", 1}
      ])
  """

  alias AshScylla.Identifier
  alias AshScylla.Search.Storage

  @doc """
  Indexes the analyzed terms for a single field of a post.

  Writes term → post_id mappings to `search_post_terms` and stores
  the set of unique terms in `search_post_fields` for future diffing.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec index(
          module(),
          String.t(),
          String.t(),
          non_neg_integer(),
          [{String.t(), pos_integer()}]
        ) :: :ok | {:error, term()}
  def index(repo, keyspace, post_id, field, terms) when is_list(terms) and terms != [] do
    cql = build_batch_cql(keyspace, post_id, field, terms)
    execute_batch(repo, cql)
  end

  @doc """
  Indexes analyzed terms across multiple fields for a post.

  Accepts a map of `%{field_num => [{term, tf}]}` and writes all rows.
  """
  @spec index_fields(
          module(),
          String.t(),
          String.t(),
          %{non_neg_integer() => [{String.t(), pos_integer()}]}
        ) :: :ok | {:error, term()}
  def index_fields(repo, keyspace, post_id, fields_map) when is_map(fields_map) do
    fields_map
    |> Enum.reduce_while(:ok, fn {field, terms}, :ok ->
      case index(repo, keyspace, post_id, field, terms) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp build_batch_cql(keyspace, post_id, field, terms) do
    ks = Identifier.quote_name(keyspace)
    table_terms = Identifier.quote_name("search_post_terms")
    table_fields = Identifier.quote_name("search_post_fields")

    statement =
      terms
      |> Enum.map(fn {term, tf} ->
        shard = Storage.shard_for(term)
        "INSERT INTO #{ks}.#{table_terms} (term, shard, post_id, field, tf) " <>
          "VALUES (#{cql_string(term)}, #{shard}, #{post_id}, #{field}, #{tf})"
      end)
      |> Enum.join(";")

    unique_terms =
      terms
      |> Enum.map(fn {term, _} -> cql_string(term) end)
      |> Enum.join(", ")

    fields_insert =
      "INSERT INTO #{ks}.#{table_fields} (post_id, field, terms) " <>
        "VALUES (#{post_id}, #{field}, {#{unique_terms}})"

    validate_cql_length!(statement <> ";" <> fields_insert)
    "BEGIN UNLOGGED BATCH\n#{statement};\n#{fields_insert};\nAPPLY BATCH;"
  end

  defp execute_batch(repo, cql) do
    case repo.query(cql, []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp cql_string(value) when is_binary(value) do
    escaped = String.replace(value, "'", "''")
    "'#{escaped}'"
  end

  defp validate_cql_length!(cql) when byte_size(cql) > 50_000_000,
    do: raise("CQL batch too large")
  defp validate_cql_length!(_cql), do: :ok
end
