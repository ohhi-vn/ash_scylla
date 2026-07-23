defmodule AshScylla.Search.Indexer do
  @moduledoc """
  Index management coordinator.

  Orchestrates indexing, updating, and deleting documents in the inverted index.
  Delegates to `Builder`, `Updater`, and `Deleter` sub-modules.

  ## Usage

      # Index a new document
      Indexer.index(repo, keyspace, post_id, %{title: "Hello World", body: "Elixir is great"})

      # Update a document
      Indexer.update(repo, keyspace, post_id, %{title: "Updated Title", body: "New content"})

      # Delete a document
      Indexer.delete(repo, keyspace, post_id)
  """

  alias AshScylla.Search.Analyzer
  alias AshScylla.Search.Indexer.{Builder, Deleter, Updater}

  @type field_map :: %{optional(atom()) => String.t()}

  @doc """
  Indexes a new document into the inverted index.

  Accepts a map of field names to text values. Each field is:
    1. Analyzed (tokenized, normalized, stemmed)
    2. Written to `search_post_terms` and `search_post_fields`

  Fields are numbered sequentially starting from 0 in the order they
  appear in the map.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec index(module(), String.t(), String.t(), field_map(), keyword()) :: :ok | {:error, term()}
  def index(repo, keyspace, post_id, fields, opts \\ []) when is_map(fields) do
    fields
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{_field_name, text}, field_num}, :ok ->
      terms = Analyzer.analyze(text, opts)

      case Builder.index(repo, keyspace, post_id, field_num, terms) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Updates a document's indexed terms.

  For each field, computes the diff between old stored terms and new
  analyzed terms, then applies only the necessary inserts and deletes.

  Fields that haven't changed are left untouched.
  """
  @spec update(module(), String.t(), String.t(), field_map(), keyword()) :: :ok | {:error, term()}
  def update(repo, keyspace, post_id, fields, opts \\ []) when is_map(fields) do
    fields
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{_field_name, text}, field_num}, :ok ->
      new_terms = Analyzer.analyze(text, opts)

      with {:ok, old_terms} <- Updater.fetch_old_terms(repo, keyspace, post_id, field_num),
           :ok <- Updater.update_field(repo, keyspace, post_id, field_num, new_terms, old_terms) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
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
  Removes a single field from the index for a document.
  """
  @spec delete_field(module(), String.t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def delete_field(repo, keyspace, post_id, field_num) do
    Deleter.delete_field(repo, keyspace, post_id, field_num)
  end
end
