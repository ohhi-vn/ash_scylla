defmodule AshScylla.Search.Analyzer do
  @moduledoc """
  Text analysis pipeline coordinator.

  Orchestrates the full text analysis pipeline:

      Document text
        → Tokenizer (split into words)
        → Normalizer (lowercase, strip punctuation, NFC normalize)
        → Stop Words filter (remove common words)
        → Stemmer (reduce to root form)
        → Unique terms with counts

  ## Usage

      iex> Analyzer.analyze("Learning Elixir Phoenix Framework")
      [{"phoenix", 1}, {"framework", 1}, {"learn", 1}, {"elixir", 1}]

  The result is a keyword list of `{term, frequency}` pairs ready for
  indexing or query processing.
  """

  alias AshScylla.Search.Analyzer.{Normalizer, Stemmer, StopWords, Tokenizer}

  @doc """
  Analyzes text and returns a list of `{term, term_frequency}` tuples.

  The terms are:
    1. Tokenized from the input text
    2. Normalized (lowercase, punctuation removal, NFC)
    3. Filtered to remove stop words
    4. Stemmed to their root form
    5. Deduplicated with frequency counts

  ## Options
    * `:stem` — whether to apply stemming (default: `true`)
    * `:remove_stop_words` — whether to remove stop words (default: `true`)
    * `:min_length` — minimum token length (default: `1`)

  ## Examples

      iex> Analyzer.analyze("The Phoenix Framework is running fast")
      [{"phoenix", 1}, {"framework", 1}, {"run", 1}, {"fast", 1}]
  """
  @spec analyze(String.t(), keyword()) :: [{String.t(), pos_integer()}]
  def analyze(text, opts \\ []) when is_binary(text) do
    stem? = Keyword.get(opts, :stem, true)
    remove_stop? = Keyword.get(opts, :remove_stop_words, true)
    min_length = Keyword.get(opts, :min_length, 1)

    terms =
      text
      |> Tokenizer.tokenize(min_length: min_length)
      |> Normalizer.normalize_terms()

    terms =
      if remove_stop? do
        StopWords.filter(terms)
      else
        terms
      end

    terms =
      if stem? do
        Enum.map(terms, &Stemmer.stem/1)
      else
        terms
      end

    count_terms(terms)
  end

  @doc """
  Analyzes a query string for search.

  Applies the same pipeline as `analyze/2` — tokenize, normalize, stop-word
  filtering, stemming — so query terms are consistent with indexed terms
  regardless of casing or punctuation.

  ## Examples

      iex> Analyzer.analyze_query("learning phoenix framework")
      ["learn", "phoenix", "framework"]
  """
  @spec analyze_query(String.t(), keyword()) :: [String.t()]
  def analyze_query(query, opts \\ []) when is_binary(query) do
    stem? = Keyword.get(opts, :stem, true)
    remove_stop? = Keyword.get(opts, :remove_stop_words, true)

    terms =
      query
      |> Tokenizer.tokenize()
      |> Normalizer.normalize_terms()

    terms =
      if remove_stop? do
        StopWords.filter(terms)
      else
        terms
      end

    if stem? do
      Stemmer.stem_all(terms)
    else
      terms
    end
  end

  defp count_terms(terms) do
    terms
    |> Enum.frequencies()
    |> Enum.to_list()
    |> Enum.sort_by(&elem(&1, 0))
  end
end
