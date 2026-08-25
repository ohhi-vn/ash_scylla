defmodule AshScylla.Search.Indexer do
  @moduledoc """
  Index management coordinator.

  Orchestrates indexing, updating, and deleting documents in the inverted index.
  Delegates to `Builder`, `Updater`, and `Deleter` sub-modules.

  Fields are identified by name, so partial updates only ever touch the
  fields present in the given map. Postings are stored at document level:
  a term shared across fields is stored once with its summed frequency, and
  updates recompute those totals from the per-field maps.

  ## Usage

      # Index a new document
      Indexer.index(repo, keyspace, post_id, %{title: "Hello World", body: "Elixir is great"})

      # Update a document
      Indexer.update(repo, keyspace, post_id, %{title: "Updated Title", body: "New content"})

      # Delete a document
      Indexer.delete(repo, keyspace, post_id)
  """

  alias AshScylla.Identifier
  alias AshScylla.Search.Analyzer
  alias AshScylla.Search.Indexer.{Builder, Deleter, Updater}
  alias AshScylla.Search.Storage

  @type field_map :: %{optional(atom() | String.t()) => String.t()}

  @doc """
  Indexes a new document into the inverted index.

  Accepts a map of field names to text values. Each field is analyzed
  (tokenized, normalized, stemmed); the per-field maps are aggregated into
  document-level postings and written in a single batch.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec index(module(), String.t(), String.t(), field_map(), keyword()) :: :ok | {:error, term()}
  def index(repo, keyspace, post_id, fields, opts \\ []) when is_map(fields) do
    with {:ok, uuid} <- Identifier.validate_uuid(post_id) do
      analyzed = analyze_fields(fields, opts)
      Builder.index(repo, keyspace, uuid, analyzed)
    end
  end

  @doc """
  Updates a document's indexed terms.

  Reads the stored per-field maps, applies the newly analyzed text for every
  field present in the map, recomputes document-level totals, and writes only
  the changed postings. Fields omitted from the map are left untouched.
  """
  @spec update(module(), String.t(), String.t(), field_map(), keyword()) :: :ok | {:error, term()}
  def update(repo, keyspace, post_id, fields, opts \\ [])

  def update(_repo, _keyspace, _post_id, fields, _opts) when fields == %{} do
    :ok
  end

  def update(repo, keyspace, post_id, fields, opts) when is_map(fields) do
    with {:ok, uuid} <- Identifier.validate_uuid(post_id),
         {:ok, stored_maps} <- Storage.fetch_field_maps(repo, keyspace, uuid) do
      provided = analyze_fields(fields, opts)

      merged_old = Storage.sum_field_maps(stored_maps)

      merged_new =
        stored_maps
        |> Map.drop(Map.keys(provided))
        |> Map.merge(provided)
        |> Storage.sum_field_maps()

      {upserts, deletes} = diff_totals(merged_old, merged_new)

      nothing_changed? =
        upserts == [] and deletes == [] and
          Map.take(stored_maps, Map.keys(provided)) ==
            Map.new(provided, fn {field, terms} -> {field, Map.new(terms)} end)

      if nothing_changed? do
        :ok
      else
        Updater.apply_diff(repo, keyspace, uuid, upserts, deletes, provided)
      end
    end
  end

  # Terms whose merged total dropped to zero are deleted; every other change
  # (new terms, frequency changes in either direction) is upserted.
  defp diff_totals(merged_old, merged_new) do
    all_terms = MapSet.union(MapSet.new(Map.keys(merged_old)), MapSet.new(Map.keys(merged_new)))

    Enum.reduce(all_terms, {[], []}, fn term, {upserts, deletes} ->
      old_tf = Map.get(merged_old, term, 0)
      new_tf = Map.get(merged_new, term, 0)

      cond do
        new_tf == old_tf -> {upserts, deletes}
        new_tf > 0 -> {[{term, new_tf} | upserts], deletes}
        true -> {upserts, [term | deletes]}
      end
    end)
  end

  @doc """
  Removes a document entirely from the inverted index.
  """
  @spec delete(module(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(repo, keyspace, post_id) do
    Deleter.delete(repo, keyspace, post_id)
  end

  @doc """
  Removes a single field from the index for a document. Shared terms keep
  their contributions from remaining fields.
  """
  @spec delete_field(module(), String.t(), String.t(), atom() | String.t()) ::
          :ok | {:error, term()}
  def delete_field(repo, keyspace, post_id, field_name) do
    Deleter.delete_field(repo, keyspace, post_id, field_name)
  end

  defp analyze_fields(fields, opts) do
    Map.new(fields, fn {field_name, text} ->
      {to_string(field_name), Analyzer.analyze(text, opts)}
    end)
  end
end
