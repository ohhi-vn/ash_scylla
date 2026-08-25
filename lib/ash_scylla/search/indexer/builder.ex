defmodule AshScylla.Search.Indexer.Builder do
  @moduledoc """
  Builds the inverted index for a document.

  Writes document-level postings — one row per `(term, post_id)` with the
  term's total frequency across all fields — to `search_post_terms`, and each
  field's term/frequency map to `search_post_fields` for later diff-based
  updates.

  A document is written in a single `UNLOGGED BATCH`.
  """

  alias AshScylla.Identifier
  alias AshScylla.Search.Storage

  @batch_max_bytes 1_000_000

  @doc """
  Indexes analyzed terms for every field of a post.

  Takes `%{"field_name" => [{term, tf}]}`; aggregates the per-field maps into
  document-level postings and writes everything in one batch.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec index(
          module(),
          String.t(),
          String.t(),
          %{String.t() => [{String.t(), pos_integer()}]}
        ) :: :ok | {:error, term()}
  def index(repo, keyspace, post_id, fields_terms)

  def index(_repo, _keyspace, _post_id, fields_terms) when fields_terms == %{} do
    :ok
  end

  def index(repo, keyspace, post_id, fields_terms) when is_map(fields_terms) do
    with {:ok, uuid} <- Identifier.validate_uuid(post_id),
         {:ok, cql} <- build_batch_cql(keyspace, uuid, fields_terms) do
      execute_batch(repo, cql)
    end
  end

  @doc """
  Builds the UNLOGGED BATCH statement that inserts document-level postings
  plus one `search_post_fields` row per non-empty field.

  Values are interpolated only after validation/escaping: `post_id` must be a
  UUID, and terms/field names become escaped CQL string literals.
  """
  @spec build_batch_cql(String.t(), String.t(), %{String.t() => [{String.t(), pos_integer()}]}) ::
          {:ok, String.t()} | {:error, :batch_too_large}
  def build_batch_cql(keyspace, post_id, fields_terms) when is_map(fields_terms) do
    ks = Identifier.quote_name(keyspace)
    table_fields = Identifier.quote_name("search_post_fields")

    posting_inserts =
      fields_terms
      |> Storage.sum_field_maps()
      |> Enum.map_join(";", &posting_insert(keyspace, post_id, &1))

    field_inserts =
      fields_terms
      |> Enum.reject(fn {_field, terms} -> terms == [] end)
      |> Enum.map_join(";", fn {field, terms} ->
        map_literal = terms_map_literal(terms)

        "INSERT INTO #{ks}.#{table_fields} (post_id, field, terms) " <>
          "VALUES (#{post_id}, #{cql_string(field)}, {#{map_literal}})"
      end)

    full = posting_inserts <> ";" <> field_inserts

    case validate_cql_length(full) do
      :ok ->
        {:ok, "BEGIN UNLOGGED BATCH\n#{posting_inserts};\n#{field_inserts};\nAPPLY BATCH;"}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Builds an UNLOGGED BATCH that upserts document-level posting rows only
  (no `search_post_fields` writes). Used by the updater.
  """
  @spec build_postings_batch_cql(String.t(), String.t(), [{String.t(), pos_integer()}]) ::
          {:ok, String.t()} | {:error, :batch_too_large}
  def build_postings_batch_cql(keyspace, post_id, terms) when is_list(terms) do
    inserts = posting_inserts(keyspace, post_id, terms)

    case validate_cql_length(inserts) do
      :ok ->
        {:ok, "BEGIN UNLOGGED BATCH\n#{inserts};\nAPPLY BATCH;"}

      {:error, _} = error ->
        error
    end
  end

  defp posting_inserts(keyspace, post_id, terms) do
    Enum.map_join(terms, ";", &posting_insert(keyspace, post_id, &1))
  end

  defp posting_insert(keyspace, post_id, {term, tf}) do
    ks = Identifier.quote_name(keyspace)
    table_terms = Identifier.quote_name("search_post_terms")
    shard = Storage.shard_for(term)

    "INSERT INTO #{ks}.#{table_terms} (term, shard, post_id, tf) " <>
      "VALUES (#{cql_string(term)}, #{shard}, #{post_id}, #{tf})"
  end

  @doc false
  @spec cql_string(term()) :: String.t()
  def cql_string(value) when is_binary(value) do
    escaped = String.replace(value, "'", "''")
    "'#{escaped}'"
  end

  defp terms_map_literal(terms) do
    terms
    |> Map.new(fn {term, tf} -> {term, tf} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(", ", fn {term, tf} -> "#{cql_string(term)}: #{tf}" end)
  end

  defp execute_batch(repo, cql) do
    case repo.query(cql, []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_cql_length(cql) when byte_size(cql) > @batch_max_bytes,
    do: {:error, :batch_too_large}

  defp validate_cql_length(_cql), do: :ok
end
