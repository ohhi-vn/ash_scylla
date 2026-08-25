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
    * Exclusions via `NOT term` or `-term`
    * Phrase queries (`"phoenix framework"`) matched as an unordered AND of
      their words (the index does not store token positions)
    * Pagination with page metadata
    * Relevance ranking (TF, TF-IDF, BM25)
    * Document updates and deletes
    * Sharded partitions with single-round-trip multi-partition lookups
    * Unicode-aware tokenization
    * Porter stemming
    * Stop word filtering
  """

  alias AshScylla.Search.Indexer
  alias AshScylla.Search.Query.{Paginator, Parser, Planner, Ranking}
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

  ## Query syntax

    * `word1 word2` — implicit AND
    * `a AND b` / `a OR b` / `a NOT b` — explicit operators (case-insensitive)
    * `-term` — exclusion, same as `NOT`
    * `"multi words"` — phrase: matches documents containing all of the
      phrase's analyzed words, in any order (the index does not store token
      positions)

  A branch with no positive terms (e.g. `-foo` alone, or a query made only of
  stop words) fails with `{:error, :missing_positive_term}`; in an `OR`
  query every branch must contain at least one positive term.

  ## Ranking options

    * `:strategy` — `:tf` (default), `:tfidf`, or `:bm25`

  For `:tfidf`/`:bm25`, corpus statistics improve scoring quality. Any
  statistic you omit is **derived from the matched result set** (document
  frequency per term, total documents, average document length), which keeps
  relative ordering sensible. For best results supply global values:

    * `:total_docs` — total number of indexed documents
    * `:doc_freqs` — `%{"stemmed_term" => df}` map; keys must be analyzed
      (stemmed) terms, e.g. produced by `Analyzer.analyze_query/2`
    * `:avg_doc_length` — average document length across the collection
    * `:doc_lengths` — `%{post_id => length}` map used by BM25 length
      normalization; without it, document length is approximated from the
      frequencies of the matched terms only

  ## Other options

    * `:page` — page number, starting at 1 (default: `1`)
    * `:page_size` — results per page (default: `20`)
    * `:num_shards` — shard count used at indexing time (default: `16`)
    * `:analyzer_opts` — options passed to the analyzer (e.g. `:stem`)

  ## Examples

      # Basic search
      {:ok, page} = Search.search(repo, keyspace, "elixir phoenix")

      # With AND/OR operators
      {:ok, page} = Search.search(repo, keyspace, "elixir OR phoenix")

      # Exclusions: docs mentioning "framework" are removed from the results
      {:ok, page} = Search.search(repo, keyspace, "phoenix -framework")
      {:ok, page} = Search.search(repo, keyspace, "phoenix NOT framework")

      # Phrase: matches documents containing both analyzed words (unordered)
      {:ok, page} = Search.search(repo, keyspace, ~s("phoenix framework"))

      # With BM25 ranking and pagination
      {:ok, page} = Search.search(repo, keyspace, "distributed web",
        strategy: :bm25, page: 1, page_size: 10)

  Returns `{:ok, page}` where `page` is a map with `:entries`, `:page_number`,
  `:total_count`, etc., or `{:error, reason}`. Notable error reasons:

    * `:empty_query` — the query string is blank
    * `:missing_positive_term` — no searchable positive terms remain after
      analysis (e.g. only stop words or only exclusions)
    * `:invalid_num_shards` — `:num_shards` option is less than 1
  """
  @spec search(module(), String.t(), String.t(), keyword()) :: search_result()
  def search(repo, keyspace, query, opts \\ []) when is_binary(query) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 20)
    strategy = Keyword.get(opts, :strategy, :tf)
    num_shards = Keyword.get(opts, :num_shards, 16)
    analyzer_opts = Keyword.get(opts, :analyzer_opts, [])

    with {:ok, ast} <- Parser.parse(query),
         {:ok, results} <-
           Planner.plan(repo, keyspace, ast, num_shards: num_shards, analyzer_opts: analyzer_opts) do
      post_scores = Map.to_list(results)
      stats = resolve_ranking_stats(results, opts)

      ranked =
        Ranking.rank(post_scores,
          strategy: strategy,
          total_docs: stats.total_docs,
          doc_freqs: stats.doc_freqs,
          avg_doc_length: stats.avg_doc_length,
          doc_lengths: Keyword.get(opts, :doc_lengths, %{})
        )

      entries =
        ranked
        |> Enum.map(fn {post_id, score, _term_scores} -> {post_id, score} end)

      Paginator.paginate(entries, page: page, page_size: page_size)
    end
  end

  # Derives corpus statistics from the matched result set for anything the
  # caller did not supply. Derived document frequency counts only matched
  # documents, so relative term weights stay sensible but absolute IDF values
  # are approximations.
  defp resolve_ranking_stats(results, opts) do
    user_dfs = Keyword.get(opts, :doc_freqs, %{})

    derived_dfs =
      results
      |> Enum.flat_map(fn {_post_id, term_scores} -> term_scores |> Enum.map(&elem(&1, 0)) end)
      |> Enum.uniq()
      |> Map.new(fn term ->
        df =
          Enum.count(results, fn {_post_id, term_scores} ->
            List.keymember?(term_scores, term, 0)
          end)

        {term, df}
      end)

    doc_freqs = Map.merge(derived_dfs, user_dfs)
    total_docs = Keyword.get(opts, :total_docs, max(map_size(results), 1))

    avg_doc_length =
      Keyword.get(opts, :avg_doc_length, default_avg_doc_length(results))

    %{total_docs: total_docs, doc_freqs: doc_freqs, avg_doc_length: avg_doc_length}
  end

  defp default_avg_doc_length(results) do
    case map_size(results) do
      0 ->
        1.0

      n ->
        total =
          results
          |> Enum.map(fn {_post_id, term_scores} ->
            term_scores |> Enum.map(&elem(&1, 1)) |> Enum.sum()
          end)
          |> Enum.sum()

        total / n
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
