defmodule AshScylla.Search do
  @moduledoc """
  A scalable multi-word search engine built on ScyllaDB using an inverted index.

  Provides Lucene/OpenSearch-style search capabilities without `LIKE`,
  `ALLOW FILTERING`, or secondary indexes.

  ## Architecture

  The search engine uses an **inverted index** approach:

      Document → Analyzer → Tokenizer → Normalizer → Stemmer
        → Stop Words → Indexer → search_post_terms table

      Query → Analyzer → Planner → Boolean Engine → Ranking → Results

  ## Quick Start

      # 1. Create search tables
      Search.create_tables(MyApp.Repo, "my_keyspace")

      # 2. Index a document
      Search.index(MyApp.Repo, "my_keyspace", "post-uuid-here", %{
        title: "Learning Elixir Phoenix Framework",
        body: "Phoenix is a distributed web framework built on Elixir."
      })

      # 3. Search
      {:ok, results} = Search.search(MyApp.Repo, "my_keyspace", "learning phoenix")
      #=> %{entries: [{"post-uuid-here", 2.0}], ...}

  ## Features

    * Single-word and multi-word AND/OR search
    * Pagination with page metadata
    * Relevance ranking (TF, TF-IDF, BM25)
    * Document updates and deletes
    * Sharded partitions to prevent hotspot term partitions
    * Unicode-aware tokenization
    * Porter stemming
    * Stop word filtering
  """

  alias AshScylla.Search.Indexer
  alias AshScylla.Search.Query.{Parser, Planner, Ranking, Paginator}
  alias AshScylla.Search.Storage

  @type field_map :: %{optional(atom()) => String.t()}
  @type search_result :: {:ok, Paginator.page()} | {:error, term()}

  @doc """
  Creates the search engine tables in the given keyspace.

  This must be called once before indexing or searching.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec create_tables(module(), String.t()) :: :ok | {:error, term()}
  defdelegate create_tables(repo, keyspace), to: Storage

  @doc """
  Drops the search engine tables from the given keyspace.
  """
  @spec drop_tables(module(), String.t()) :: :ok | {:error, term()}
  defdelegate drop_tables(repo, keyspace), to: Storage

  @doc """
  Indexes a document into the search engine.

  Accepts a map of field names to text values. Each field is analyzed
  and its terms are written to the inverted index.

  Returns `:ok` or `{:error, reason}`.

  ## Examples

      Search.index(MyApp.Repo, "my_keyspace", "abc-123", %{
        title: "Learning Elixir",
        body: "Elixir is a functional language"
      })
  """
  @spec index(module(), String.t(), String.t(), field_map(), keyword()) :: :ok | {:error, term()}
  defdelegate index(repo, keyspace, post_id, fields, opts \\ []), to: Indexer

  @doc """
  Updates a document's indexed terms.

  Computes the diff between old and new terms for each field, applying
  only the necessary inserts and deletes. Fields omitted from the map
  are left unchanged.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec update(module(), String.t(), String.t(), field_map(), keyword()) :: :ok | {:error, term()}
  defdelegate update(repo, keyspace, post_id, fields, opts \\ []), to: Indexer

  @doc """
  Removes a document from the search index.

  Deletes all term entries for the given post ID from both
  `search_post_terms` and `search_post_fields`.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec delete(module(), String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate delete(repo, keyspace, post_id), to: Indexer

  @doc """
  Searches the inverted index for documents matching the query.

  The full search pipeline:
    1. Parse query string into AST
    2. Analyze query terms
    3. Look up posting lists from ScyllaDB
    4. Apply boolean operations (AND/OR/NOT)
    5. Rank results by relevance
    6. Paginate results

  ## Options

    * `:page` — page number, starting at 1 (default: `1`)
    * `:page_size` — results per page (default: `20`)
    * `:strategy` — ranking strategy: `:tf` (default), `:tfidf`, `:bm25`
    * `:num_shards` — shard count per term partition (default: `16`)
    * `:analyzer_opts` — options passed to the analyzer (e.g. `:stem`)

  ## Examples

      # Basic search
      {:ok, page} = Search.search(repo, keyspace, "elixir phoenix")

      # With AND/OR operators
      {:ok, page} = Search.search(repo, keyspace, "elixir OR phoenix")

      # With BM25 ranking and pagination
      {:ok, page} = Search.search(repo, keyspace, "distributed web",
        strategy: :bm25, page: 1, page_size: 10)

  Returns `{:ok, page}` where `page` is a map with `:entries`, `:page_number`,
  `:total_count`, etc., or `{:error, reason}`.
  """
  @spec search(module(), String.t(), String.t(), keyword()) :: search_result()
  def search(repo, keyspace, query, opts \\ []) when is_binary(query) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 20)
    strategy = Keyword.get(opts, :strategy, :tf)
    num_shards = Keyword.get(opts, :num_shards, 16)
    analyzer_opts = Keyword.get(opts, :analyzer_opts, [])

    with {:ok, ast} <- Parser.parse(query),
         {:ok, results} <- Planner.plan(repo, keyspace, ast,
           num_shards: num_shards, analyzer_opts: analyzer_opts) do
      post_scores = results |> Map.to_list()

      ranked =
        Ranking.rank(post_scores,
          strategy: strategy,
          total_docs: Keyword.get(opts, :total_docs, 1),
          doc_freqs: Keyword.get(opts, :doc_freqs, %{}),
          avg_doc_length: Keyword.get(opts, :avg_doc_length, 1.0)
        )

      entries =
        ranked
        |> Enum.map(fn {post_id, score, _term_scores} -> {post_id, score} end)

      Paginator.paginate(entries, page: page, page_size: page_size)
    end
  end

  @doc """
  Same as `search/4` but raises on error.
  """
  @spec search!(module(), String.t(), String.t(), keyword()) :: Paginator.page() | no_return()
  def search!(repo, keyspace, query, opts \\ []) do
    case search(repo, keyspace, query, opts) do
      {:ok, page} -> page
      {:error, reason} -> raise "Search failed: #{inspect(reason)}"
    end
  end
end
