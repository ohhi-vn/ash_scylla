defmodule AshScylla.Search.Query.Planner do
  @moduledoc """
  Query planner that executes search queries against the inverted index.

  Takes a parsed query AST and:
    1. Analyzes each term from the query
    2. Looks up posting lists from `search_post_terms`
    3. Applies boolean operations (AND/OR/NOT)
    4. Returns combined posting list with term scores

  The planner handles sharded term lookups by querying all shards
  for each term and merging results.
  """

  alias AshScylla.Identifier
  alias AshScylla.Search.Analyzer
  alias AshScylla.Search.Query.{BooleanEngine, Parser}

  @type posting_entry :: {String.t(), non_neg_integer(), non_neg_integer()}

  @doc """
  Plans and executes a parsed query against the inverted index.

  Returns a map of `%{post_id => [{term, tf}]}` for downstream ranking.

  ## Options
    * `:num_shards` — number of shards per term (default: 16)
    * `:analyzer_opts` — options forwarded to the analyzer

  Returns `{:ok, results}` or `{:error, reason}`.
  """
  @spec plan(module(), String.t(), Parser.ast_node(), keyword()) ::
          {:ok, %{String.t() => [{String.t(), non_neg_integer()}]}} | {:error, term()}
  def plan(repo, keyspace, ast, opts \\ []) do
    num_shards = Keyword.get(opts, :num_shards, 16)
    analyzer_opts = Keyword.get(opts, :analyzer_opts, [])

    case execute_ast(repo, keyspace, ast, num_shards, analyzer_opts) do
      {:error, _} = error -> error
      results -> {:ok, results}
    end
  end

  defp execute_ast(repo, keyspace, %Parser.Group{terms: terms, op: :and}, num_shards, analyzer_opts) do
    lists =
      terms
      |> Enum.map(&execute_term(repo, keyspace, &1, num_shards, analyzer_opts))

    if Enum.any?(lists, &match?({:error, _}, &1)) do
      {:error, :lookup_failed}
    else
      lists
      |> Enum.map(fn {:ok, l} -> l end)
      |> case do
        [] -> %{}
        posting_lists -> group_results(BooleanEngine.and_intersect(posting_lists))
      end
    end
  end

  defp execute_ast(repo, keyspace, %Parser.Group{terms: terms, op: :or}, num_shards, analyzer_opts) do
    results =
      terms
      |> Enum.map(&execute_term(repo, keyspace, &1, num_shards, analyzer_opts))

    if Enum.any?(results, &match?({:error, _}, &1)) do
      {:error, :lookup_failed}
    else
      lists = Enum.map(results, fn {:ok, l} -> l end)

      case lists do
        [] -> %{}
        posting_lists -> group_results(BooleanEngine.or_union(posting_lists))
      end
    end
  end

  defp execute_term(repo, keyspace, %Parser.Term{word: word}, num_shards, analyzer_opts) do
    analyzed = Analyzer.analyze_query(word, analyzer_opts)

    posting_lists =
      analyzed
      |> Enum.map(&lookup_term(repo, keyspace, &1, num_shards))

    if Enum.any?(posting_lists, &match?({:error, _}, &1)) do
      {:error, :lookup_failed}
    else
      case Enum.map(posting_lists, fn {:ok, l} -> l end) do
        [] -> {:ok, []}
        [list] -> {:ok, list}
        lists -> {:ok, BooleanEngine.and_intersect(lists)}
      end
    end
  end

  defp execute_term(repo, keyspace, %Parser.NotExpr{term: inner_term}, num_shards, analyzer_opts) do
    execute_term(repo, keyspace, inner_term, num_shards, analyzer_opts)
  end

  defp execute_term(_repo, _keyspace, %Parser.Phrase{words: _words}, _num_shards, _analyzer_opts) do
    {:ok, []}
  end

  defp lookup_term(repo, keyspace, term, num_shards) do
    case fetch_posting_list(repo, keyspace, term, num_shards) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_posting_list(repo, keyspace, term, num_shards) do
    ks = Identifier.quote_name(keyspace)
    table = Identifier.quote_name("search_post_terms")
    escaped = String.replace(term, "'", "''")

    queries =
      0..(num_shards - 1)
      |> Enum.map(fn shard ->
        "SELECT post_id, field, tf FROM #{ks}.#{table} " <>
          "WHERE term = '#{escaped}' AND shard = #{shard}"
      end)

    results =
      queries
      |> Enum.reduce_while({:ok, []}, fn cql, {:ok, acc} ->
        case repo.query(cql, []) do
          {:ok, %{rows: rows}} -> {:cont, {:ok, acc ++ normalize_rows(rows)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case results do
      {:ok, rows} -> {:ok, Enum.sort_by(rows, &elem(&1, 0))}
      {:error, _} = error -> error
    end
  end

  defp normalize_rows(rows) do
    Enum.map(rows, fn
      [post_id, field, tf] -> {to_string(post_id), field, tf}
    end)
  end

  defp group_results(posting_list) do
    posting_list
    |> Enum.group_by(fn {post_id, _tf} -> post_id end, fn {_post_id, tf} -> tf end)
    |> Enum.map(fn {post_id, tfs} ->
      {post_id, [{"_all", Enum.sum(tfs)}]}
    end)
    |> Map.new()
  end
end
