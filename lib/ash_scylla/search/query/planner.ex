defmodule AshScylla.Search.Query.Planner do
  @moduledoc """
  Query planner that executes search queries against the inverted index.

  Takes a parsed query AST and:
    1. Analyzes each term from the query
    2. Looks up posting lists from `search_post_terms` — one multi-partition,
       fully-paged query per analyzed term (`shard IN (0..n-1)`); terms within
       a group are fetched concurrently
    3. Applies boolean operations (AND/OR/NOT)
    4. Returns a map of `%{post_id => [{term, tf}]}` for downstream ranking,
       keyed by the real analyzed terms so per-term statistics (doc frequency)
       remain usable

  ## Boolean semantics

    * `AND` groups (explicit or implicit) — intersection of all positive
      terms, minus documents matching any excluded term (`NOT term` or `-term`)
    * `OR` groups — union of branches; each branch is evaluated as an
      independent AND group
    * Phrases (`"phoenix framework"`) — matched as an unordered AND of their
      analyzed words. The index does not store token positions, so word order
      is not verified.
    * Stop words contribute nothing: a positive term that analyzes to zero
      terms is dropped, and a query with no remaining positive terms fails
      with `{:error, :missing_positive_term}`.
  """

  alias AshScylla.Identifier
  alias AshScylla.Search.Analyzer
  alias AshScylla.Search.Query.Parser

  @default_num_shards 16
  @max_fetch_concurrency 8

  @typedoc "Matched documents with their per-term scores."
  @type scored_results :: %{String.t() => [{String.t(), non_neg_integer()}]}

  @doc """
  Plans and executes a parsed query against the inverted index.

  Returns `{:ok, results}` where results maps each matching `post_id` to its
  `[{term, tf}]` contributions, or `{:error, reason}`.

  ## Options

    * `:num_shards` — number of shards used at indexing time (default: 16)
    * `:analyzer_opts` — options forwarded to the analyzer

  ## Errors

    * `{:error, :invalid_num_shards}` — `:num_shards` is less than 1
    * `{:error, :missing_positive_term}` — the query has no searchable
      positive terms (e.g. only stop words or only exclusions)
    * `{:error, reason}` — propagated from the repo lookup
  """
  @spec plan(module(), String.t(), Parser.ast_node(), keyword()) ::
          {:ok, scored_results()} | {:error, term()}
  def plan(repo, keyspace, ast, opts \\ []) do
    num_shards = Keyword.get(opts, :num_shards, @default_num_shards)
    analyzer_opts = Keyword.get(opts, :analyzer_opts, [])

    if is_integer(num_shards) and num_shards >= 1 do
      execute_ast(repo, keyspace, ast, num_shards, analyzer_opts)
    else
      {:error, :invalid_num_shards}
    end
  end

  # The parser always returns a top-level %Group{}.

  defp execute_ast(
         repo,
         keyspace,
         %Parser.Group{terms: terms, op: :and},
         num_shards,
         analyzer_opts
       ) do
    execute_and_group(repo, keyspace, terms, num_shards, analyzer_opts)
  end

  defp execute_ast(
         repo,
         keyspace,
         %Parser.Group{terms: branches, op: :or},
         num_shards,
         analyzer_opts
       ) do
    branch_maps =
      parallel_map(branches, &execute_branch(&1, repo, keyspace, num_shards, analyzer_opts))

    case collect_errors(branch_maps) do
      {:error, _} = error -> error
      branch_maps -> {:ok, union_maps(branch_maps)}
    end
  end

  defp execute_branch(
         %Parser.Group{terms: inner_terms, op: :and},
         repo,
         keyspace,
         num_shards,
         analyzer_opts
       ) do
    execute_and_group(repo, keyspace, inner_terms, num_shards, analyzer_opts)
  end

  # Bare leaves inside OR groups are treated as one-term AND groups.
  defp execute_branch(leaf, repo, keyspace, num_shards, analyzer_opts) do
    execute_and_group(repo, keyspace, [leaf], num_shards, analyzer_opts)
  end

  # An AND group matches the intersection of its positive terms minus every
  # document matching an excluded (NOT / -prefixed) term.
  defp execute_and_group(repo, keyspace, terms, num_shards, analyzer_opts) do
    {positives, negatives} = Enum.split_with(terms, &(!match?(%Parser.NotExpr{}, &1)))
    negative_leaves = Enum.map(negatives, fn %Parser.NotExpr{term: leaf} -> leaf end)

    positive_maps =
      parallel_map(positives, &leaf_postings(repo, keyspace, &1, num_shards, analyzer_opts))

    negative_maps =
      parallel_map(negative_leaves, &leaf_postings(repo, keyspace, &1, num_shards, analyzer_opts))

    with {:ok, positive_maps} <- unwrap(positive_maps),
         {:ok, negative_maps} <- unwrap(negative_maps) do
      # `nil` marks a neutral leaf (analyzed to zero terms, e.g. stop words):
      # it imposes no constraint. An empty map means real postings were found
      # to be empty and must still constrain the intersection.
      positive_maps = Enum.reject(positive_maps, &is_nil/1)

      case positive_maps do
        [] ->
          {:error, :missing_positive_term}

        maps ->
          included = intersect_maps(maps)

          excluded =
            negative_maps |> Enum.reject(&is_nil/1) |> Enum.flat_map(&Map.keys/1) |> MapSet.new()

          {:ok, Map.drop(included, MapSet.to_list(excluded))}
      end
    end
  end

  # A single word may analyze into several tokens (e.g. punctuation splits);
  # all variants must match, mirroring AND behaviour across variants.
  defp leaf_postings(repo, keyspace, %Parser.Term{word: word}, num_shards, analyzer_opts) do
    word
    |> Analyzer.analyze_query(analyzer_opts)
    |> Enum.uniq()
    |> fetch_terms_intersect(repo, keyspace, num_shards)
  end

  # The index stores no token positions, so phrases match documents containing
  # all of their analyzed words (unordered).
  defp leaf_postings(repo, keyspace, %Parser.Phrase{words: words}, num_shards, analyzer_opts) do
    words
    |> Enum.flat_map(&Analyzer.analyze_query(&1, analyzer_opts))
    |> Enum.uniq()
    |> fetch_terms_intersect(repo, keyspace, num_shards)
  end

  # An empty analysis (pure stop words) imposes no constraint.
  defp fetch_terms_intersect([], _repo, _keyspace, _num_shards), do: {:ok, nil}

  defp fetch_terms_intersect(terms, repo, keyspace, num_shards) do
    results = parallel_map(terms, &fetch_term(repo, keyspace, &1, num_shards))

    case collect_errors(results) do
      {:error, _} = error -> error
      maps -> {:ok, intersect_maps(maps)}
    end
  end

  # One round trip per analyzed term: `shard IN (...)` scans all shards in a
  # single multi-partition query, keeping results correct even when the shard
  # count differs from the one used at indexing time. Postings are stored at
  # document level, so each row is `[post_id, tf]`.
  #
  # Repos built with AshScylla.Repo expose query_all/3, which follows CQL
  # paging so hot terms larger than one page are never truncated. Generic
  # repos fall back to a plain query (single page).
  defp fetch_term(repo, keyspace, term, num_shards) do
    ks = Identifier.quote_name(keyspace)
    table = Identifier.quote_name("search_post_terms")
    shards = Enum.join(Enum.to_list(0..(num_shards - 1)), ", ")

    cql =
      "SELECT post_id, tf FROM #{ks}.#{table} " <>
        "WHERE term = ? AND shard IN (#{shards})"

    result =
      if function_exported?(repo, :query_all, 3) do
        repo.query_all(cql, [term], [])
      else
        repo.query(cql, [term])
      end

    case normalize_result(result) do
      {:ok, rows} -> {:ok, rows_to_map(rows, term)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_result({:ok, %{rows: rows}}), do: {:ok, rows}
  defp normalize_result({:ok, %Xandra.Page{content: content}}), do: {:ok, List.wrap(content)}
  defp normalize_result({:error, reason}), do: {:error, reason}

  defp rows_to_map(rows, term) do
    Enum.reduce(rows, %{}, fn
      [post_id, tf], acc ->
        Map.put(acc, to_string(post_id), [{term, tf}])

      _, acc ->
        acc
    end)
  end

  # Intersection on post_id; per-post term scores are merged by summing
  # duplicate terms. Driven from the smallest map so cost scales with the
  # rarest term rather than allocating key sets of every posting list.
  defp intersect_maps([]), do: %{}

  defp intersect_maps(maps) do
    [smallest | rest] = Enum.sort_by(maps, &map_size/1)

    smallest
    |> Enum.filter(fn {post_id, _scores} ->
      Enum.all?(rest, &Map.has_key?(&1, post_id))
    end)
    |> Map.new(fn {post_id, scores} ->
      {post_id, merge_scores([scores | Enum.map(rest, &Map.fetch!(&1, post_id))])}
    end)
  end

  defp union_maps([]), do: %{}
  defp union_maps([single]), do: single

  defp union_maps(maps) do
    Enum.reduce(maps, %{}, fn map, acc ->
      Map.merge(acc, map, fn _post_id, scores_a, scores_b ->
        merge_scores([scores_a, scores_b])
      end)
    end)
  end

  defp merge_scores(score_lists) do
    score_lists
    |> Enum.reduce(%{}, fn scores, acc ->
      Enum.reduce(scores, acc, fn {term, tf}, m -> Map.update(m, term, tf, &(&1 + tf)) end)
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  # ── Concurrency helpers ──────────────────────────────────────────────────

  # Independent lookups run concurrently so multi-term query latency tracks
  # the slowest posting list rather than the sum of all of them. Single items
  # run inline — spawning a task costs more than the lookup itself.
  defp parallel_map([], _fun), do: []
  defp parallel_map([item], fun), do: [fun.(item)]

  defp parallel_map(items, fun) do
    items
    |> Task.async_stream(fun, max_concurrency: @max_fetch_concurrency, ordered: true)
    |> Enum.map(fn {:ok, value} -> value end)
  end

  defp unwrap(results) do
    case collect_errors(results) do
      {:error, _} = error -> error
      values -> {:ok, values}
    end
  end

  defp collect_errors(results) do
    Enum.find(results, &match?({:error, _}, &1)) ||
      Enum.map(results, fn {:ok, value} -> value end)
  end
end
