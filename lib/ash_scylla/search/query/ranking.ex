defmodule AshScylla.Search.Query.Ranking do
  @moduledoc """
  Ranking and relevance scoring for search results.

  Supports two scoring strategies:

    * `:tf` — Simple Term Frequency scoring
    * `:tfidf` — TF-IDF (Term Frequency × Inverse Document Frequency)
    * `:bm25` — BM25 (Okapi BM25) probabilistic relevance scoring

  ## BM25 Formula

      score(D, Q) = Σ IDF(qi) × (tf(qi, D) × (k1 + 1)) / (tf(qi, D) + k1 × (1 − b + b × (|D| / avgdl)))

  Where:
    * tf(qi, D) = term frequency of term qi in document D
    * |D| = document length (sum of all TF in document)
    * avgdl = average document length across the collection
    * k1 = term frequency saturation (default 1.2)
    * b = length normalization (default 0.75)
  """

  @type result :: {String.t(), float(), [{String.t(), non_neg_integer()}]}

  @doc """
  Ranks results using the specified strategy.

  Returns a list of `{post_id, score, term_scores}` tuples sorted by
  descending score.

  ## Options
    * `:strategy` — `:tf` (default), `:tfidf`, or `:bm25`
    * `:k1` — BM25 k1 parameter (default 1.2)
    * `:b` — BM25 b parameter (default 0.75)
    * `:total_docs` — total document count (for IDF, required for TF-IDF/BM25)
    * `:doc_freqs` — %{term => doc_freq} map (for IDF, required for TF-IDF/BM25)
    * `:avg_doc_length` — average document length (for BM25)
  """
  @spec rank(
          [{String.t(), [{String.t(), non_neg_integer()}]}],
          keyword()
        ) :: [result()]
  def rank(results, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :tf)

    case strategy do
      :tf -> rank_by_tf(results)
      :tfidf -> rank_by_tfidf(results, opts)
      :bm25 -> rank_by_bm25(results, opts)
      _ -> rank_by_tf(results)
    end
  end

  @doc """
  Computes the IDF (Inverse Document Frequency) for a term.

      IDF(t) = log(1 + (N − df(t) + 0.5) / (df(t) + 0.5))

  Where N is the total number of documents and df(t) is the number of
  documents containing the term.
  """
  @spec idf(non_neg_integer(), non_neg_integer()) :: float()
  def idf(total_docs, doc_freq) when total_docs > 0 and doc_freq > 0 do
    :math.log(1 + (total_docs - doc_freq + 0.5) / (doc_freq + 0.5))
  end

  def idf(_total_docs, 0), do: 0.0
  def idf(0, _doc_freq), do: 0.0

  defp rank_by_tf(results) do
    results
    |> Enum.map(fn {post_id, term_scores} ->
      total_tf = term_scores |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      {post_id, total_tf / 1, term_scores}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  defp rank_by_tfidf(results, opts) do
    total_docs = Keyword.get(opts, :total_docs, 1)
    doc_freqs = Keyword.get(opts, :doc_freqs, %{})

    results
    |> Enum.map(fn {post_id, term_scores} ->
      score =
        term_scores
        |> Enum.map(fn {term, tf} ->
          df = Map.get(doc_freqs, term, 1)
          tf * idf(total_docs, df)
        end)
        |> Enum.sum()

      {post_id, score, term_scores}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  defp rank_by_bm25(results, opts) do
    total_docs = Keyword.get(opts, :total_docs, 1)
    doc_freqs = Keyword.get(opts, :doc_freqs, %{})
    avg_doc_length = Keyword.get(opts, :avg_doc_length, 1.0)
    k1 = Keyword.get(opts, :k1, 1.2)
    b = Keyword.get(opts, :b, 0.75)

    results
    |> Enum.map(fn {post_id, term_scores} ->
      score =
        term_scores
        |> Enum.map(fn {term, tf} ->
          df = Map.get(doc_freqs, term, 1)
          idf_val = idf(total_docs, df)
          doc_length = Enum.sum(Enum.map(term_scores, &elem(&1, 1)))
          bm25 = (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * (doc_length / max(avg_doc_length, 1))))
          idf_val * bm25
        end)
        |> Enum.sum()

      {post_id, score, term_scores}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end
end
