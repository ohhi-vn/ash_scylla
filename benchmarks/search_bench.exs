#!/usr/bin/env elixir

# Search feature benchmarks for AshScylla
#
# Measures the CPU cost of every stage of the search pipeline — no database
# connection is required. Paths that normally hit ScyllaDB use an in-memory
# repo, so results reflect library overhead (CQL building, result shaping,
# boolean logic, ranking) rather than network/disk latency.
#
# Run with: MIX_ENV=dev mix run benchmarks/search_bench.exs
# Or:       make bench-search
#
# Environment overrides:
#   SEARCH_BENCH_TIME   seconds per scenario (default: 2)
#   SEARCH_BENCH_WARMUP seconds warmup per scenario (default: 0.5)
#   SEARCH_BENCH_DOCS   corpus size for index/result scenarios (default: 10000).
#                       Frequent terms match DOCS posts, mid terms DOCS/10,
#                       rare terms DOCS/100.

defmodule AshScylla.Benchmarks.Search do
  @moduledoc """
  Performance benchmarks for the AshScylla.Search inverted-index engine.

  ## Scenarios

    * Analyzer      — document/query text analysis at several sizes
    * Parser        — query-string parsing across syntax complexity
    * BooleanEngine — intersect/union/difference over posting lists (O(n+m))
    * Planner       — query planning against an in-memory index (library overhead)
    * Builder       — UNLOGGED BATCH CQL construction while indexing
    * Ranking       — TF / TF-IDF / BM25 scoring of result sets
    * Paginator     — pagination metadata over large result lists
    * End-to-end    — full `AshScylla.Search.search/4` pipeline via mock repo

  ## Usage

      MIX_ENV=dev mix run benchmarks/search_bench.exs
      SEARCH_BENCH_DOCS=100000 MIX_ENV=dev mix run benchmarks/search_bench.exs
  """

  alias AshScylla.Search
  alias AshScylla.Search.Analyzer
  alias AshScylla.Search.Indexer.Builder
  alias AshScylla.Search.Query.{BooleanEngine, Parser, Planner, Paginator, Ranking}

  @uuid "550e8400-e29b-41d4-a716-446655440000"
  @num_shards 16

  defmodule MemoryIndexRepo do
    @moduledoc false
    # Serves pre-built posting rows keyed by term. Row shape matches Xandra:
    # [post_id, tf]. Backed by :persistent_term so the lookup itself adds no
    # measurable overhead.
    def query(_cql, [term]) do
      {:ok, %{rows: postings(term)}}
    end

    defp postings(term) do
      :persistent_term.get({__MODULE__, :index}, %{}) |> Map.get(term, [])
    end

    def load(index) do
      :persistent_term.put({__MODULE__, :index}, index)
    end
  end

  def run do
    unless Code.ensure_loaded?(Benchee) do
      raise "benchee is not available. Run with: MIX_ENV=dev mix run benchmarks/search_bench.exs"
    end

    time = float_env("SEARCH_BENCH_TIME", 2.0)
    warmup = float_env("SEARCH_BENCH_WARMUP", 0.5)
    docs = int_env("SEARCH_BENCH_DOCS", 10_000)

    docs_fmt = docs_to_string(docs)
    frequent = docs
    mid = max(div(docs, 10), 1)
    rare = max(div(docs, 100), 1)

    MemoryIndexRepo.load(mock_index(frequent, mid, rare))

    data = prebuilt_data(frequent, mid)

    %{and3: and3_ast, or3: or3_ast, not_ast: not_ast, phrase: phrase_ast} =
      parsed_asts()

    IO.puts("""

    ──────────────────────────────────────────────────────────────
    AshScylla.Search benchmarks (time: #{time}s/scenario, warmup: #{warmup}s)
    Corpus: #{docs_fmt} documents — frequent=#{docs_fmt}, mid=#{docs_to_string(mid)}, rare=#{docs_to_string(rare)} posts/term
    ──────────────────────────────────────────────────────────────
    """)

    Benchee.run(
      %{
        # ── Analyzer ────────────────────────────────────────────────────
        "analyzer/title (~5 words)" => fn -> Analyzer.analyze(short_text()) end,
        "analyzer/paragraph (~60 words)" => fn -> Analyzer.analyze(medium_text()) end,
        "analyzer/document (~600 words)" => fn -> Analyzer.analyze(large_text()) end,
        "analyzer/document, no stemming" => fn ->
          Analyzer.analyze(large_text(), stem: false)
        end,
        "analyzer/query (3 words)" => fn ->
          Analyzer.analyze_query("distributed web framework")
        end,

        # ── Parser ──────────────────────────────────────────────────────
        "parser/single word" => fn -> Parser.parse("phoenix") end,
        "parser/implicit AND (4 words)" => fn ->
          Parser.parse("learning phoenix framework today")
        end,
        "parser/OR groups" => fn -> Parser.parse("elixir OR phoenix OR erlang") end,
        "parser/NOT + minus prefix" => fn ->
          Parser.parse("phoenix -framework NOT livebook")
        end,
        "parser/phrase + word + exclusion" => fn ->
          Parser.parse(~s("web framework" elixir -otp))
        end,

        # ── BooleanEngine ───────────────────────────────────────────────
        "boolean/intersect 100 x 100" => fn ->
          BooleanEngine.intersect_scored(data.pair_100)
        end,
        "boolean/intersect #{docs_to_string(mid)} x #{docs_to_string(mid)}" => fn ->
          BooleanEngine.intersect_scored(data.pair_mid)
        end,
        "boolean/union #{docs_to_string(frequent)} x #{docs_to_string(mid)}" => fn ->
          BooleanEngine.union_scored([data.list_frequent, data.list_mid])
        end,
        "boolean/not_difference #{docs_to_string(frequent)} - #{docs_to_string(mid)}" => fn ->
          BooleanEngine.not_difference(data.triples_frequent, data.triples_mid)
        end,

        # ── Planner (in-memory index; library overhead only) ────────────
        "planner/single rare term" => fn ->
          Planner.plan(MemoryIndexRepo, "ks", elem(Parser.parse("distributed"), 1),
            num_shards: @num_shards
          )
        end,
        "planner/AND 3 mixed terms" => fn ->
          Planner.plan(MemoryIndexRepo, "ks", and3_ast, num_shards: @num_shards)
        end,
        "planner/OR frequent+mid+rare" => fn ->
          Planner.plan(MemoryIndexRepo, "ks", or3_ast, num_shards: @num_shards)
        end,
        "planner/AND + NOT" => fn ->
          Planner.plan(MemoryIndexRepo, "ks", not_ast, num_shards: @num_shards)
        end,
        "planner/phrase (2 mid terms)" => fn ->
          Planner.plan(MemoryIndexRepo, "ks", phrase_ast, num_shards: @num_shards)
        end,

        # ── Indexer.Builder (CQL construction) ──────────────────────────
        "builder/batch CQL 10 terms" => fn ->
          {:ok, _} = Builder.build_batch_cql("ks", @uuid, %{"body" => data.terms_10})
          :ok
        end,
        "builder/batch CQL 100 terms" => fn ->
          {:ok, _} = Builder.build_batch_cql("ks", @uuid, %{"body" => data.terms_100})
          :ok
        end,
        "builder/batch CQL 500 terms" => fn ->
          {:ok, _} = Builder.build_batch_cql("ks", @uuid, %{"body" => data.terms_500})
          :ok
        end,

        # ── Ranking ─────────────────────────────────────────────────────
        "ranking/tf #{docs_to_string(mid)} docs" => fn ->
          Ranking.rank(data.results_mid, strategy: :tf)
        end,
        "ranking/tfidf #{docs_to_string(mid)} docs" => fn ->
          Ranking.rank(data.results_mid,
            strategy: :tfidf,
            total_docs: docs,
            doc_freqs: doc_freqs()
          )
        end,
        "ranking/bm25 #{docs_to_string(mid)} docs" => fn ->
          Ranking.rank(data.results_mid,
            strategy: :bm25,
            total_docs: docs,
            doc_freqs: doc_freqs(),
            avg_doc_length: 50.0
          )
        end,

        # ── Paginator ───────────────────────────────────────────────────
        "paginator/#{docs_to_string(frequent)} entries, page 1" => fn ->
          {:ok, _} = Paginator.paginate(data.entries_frequent, page: 1, page_size: 20)
          :ok
        end,
        "paginator/#{docs_to_string(frequent)} entries, deep page" => fn ->
          {:ok, _} = Paginator.paginate(data.entries_frequent, page: 500, page_size: 20)
          :ok
        end,

        # ── End-to-end (mock repo; no DB) ───────────────────────────────
        "search/end-to-end AND, bm25" => fn ->
          {:ok, _page} =
            Search.search(MemoryIndexRepo, "ks", "elixir framework", strategy: :bm25)

          :ok
        end,
        "search/end-to-end OR ranked, tf" => fn ->
          {:ok, _page} =
            Search.search(MemoryIndexRepo, "ks", "elixir OR phoenix OR framework",
              strategy: :tf,
              page_size: 20
            )

          :ok
        end,
        "search/end-to-end AND + NOT, bm25" => fn ->
          {:ok, _page} =
            Search.search(MemoryIndexRepo, "ks", "web -distributed", strategy: :bm25)

          :ok
        end
      },
      time: time,
      warmup: warmup,
      memory_time: float_env("SEARCH_BENCH_MEMORY", time),
      parallel: 1,
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.HTML, file: "benchmarks/results/search.html",
         auto_open: false}
      ]
    )
  end

  # ── Pre-built data (kept outside measured closures) ───────────────────────

  defp prebuilt_data(frequent, mid) do
    list_mid_a = scored_list(mid, "pa")
    list_mid_b = scored_list(mid, "pb")
    list_frequent = scored_list(frequent, "pf")

    %{
      pair_100: [scored_list(100, "pa"), scored_list(100, "pb")],
      pair_mid: [list_mid_a, list_mid_b],
      list_frequent: list_frequent,
      list_mid: list_mid_b,
      triples_frequent: to_triples(list_frequent),
      triples_mid: to_triples(list_mid_b),
      terms_10: terms_with_tf(10),
      terms_100: terms_with_tf(100),
      terms_500: terms_with_tf(500),
      results_mid: results(mid),
      entries_frequent: scored_list(frequent, "pe")
    }
  end

  defp parsed_asts do
    {:ok, and3} = Parser.parse("elixir framework distributed")
    {:ok, or3} = Parser.parse("elixir OR phoenix OR framework")
    {:ok, not_ast} = Parser.parse("phoenix framework -liveview")
    {:ok, phrase} = Parser.parse(~s("web framework"))

    %{and3: and3, or3: or3, not_ast: not_ast, phrase: phrase}
  end

  defp scored_list(n, prefix) do
    Enum.map(1..n, fn i -> {"#{prefix}-#{i}", rem(i, 5) + 1} end)
  end

  defp to_triples(scored) do
    Enum.map(scored, fn {id, tf} -> {id, 0, tf} end)
  end

  defp results(n) do
    Enum.map(1..n, fn i ->
      {"post-#{i}", [{"elixir", rem(i, 3) + 1}, {"framework", rem(i, 2) + 1}]}
    end)
  end

  defp doc_freqs do
    %{"elixir" => 900, "framework" => 400, "distributed" => 250, "phoenix" => 700}
  end

  defp terms_with_tf(n) do
    Enum.map(1..n, fn i -> {"term#{i}", rem(i, 9) + 1} end)
  end

  # ── Mock index ────────────────────────────────────────────────────────────

  # Deterministic in-memory index. All terms draw from ONE shared post-id
  # space of `frequent` documents (like a real corpus where docs contain many
  # terms), so AND/OR intersections are realistic.
  defp mock_index(frequent, mid, rare) do
    %{
      "phoenix" => rows(frequent),
      "web" => rows(frequent),
      "elixir" => rows(mid),
      "framework" => rows(mid),
      "distributed" => rows(rare),
      "liveview" => rows(rare)
    }
  end

  defp rows(count) do
    Enum.map(0..(count - 1), fn i ->
      ["post-#{i + 1}", rem(i, 5) + 1]
    end)
  end

  # ── Text corpora ──────────────────────────────────────────────────────────

  defp short_text, do: "Learning Elixir Phoenix Framework"

  defp medium_text do
    sentences() |> Enum.take(4) |> Enum.join(" ")
  end

  defp large_text do
    sentences() |> Stream.cycle() |> Enum.take(40) |> Enum.join(" ")
  end

  defp sentences do
    [
      "Phoenix is a productive web framework built on the Elixir programming language.",
      "The framework distributes requests across many lightweight processes.",
      "Elixir leverages the Erlang virtual machine for fault-tolerant systems.",
      "LiveView enables rich real-time interfaces without JavaScript.",
      "Distributed applications scale horizontally across clustered nodes.",
      "The database layer generates efficient CQL statements for ScyllaDB.",
      "Inverted indexes map analyzed terms back to document identifiers.",
      "Relevance ranking balances term frequency against document rarity."
    ]
  end

  # ── Env/format helpers ────────────────────────────────────────────────────

  defp float_env(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_float(value <> if(String.contains?(value, "."), do: "", else: ".0"))
    end
  end

  defp int_env(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  defp docs_to_string(n) when n >= 1_000_000, do: "#{div(n, 1_000_000)}M"
  defp docs_to_string(n) when rem(n, 1000) == 0, do: "#{div(n, 1000)}k"
  defp docs_to_string(n), do: Integer.to_string(n)
end

AshScylla.Benchmarks.Search.run()
