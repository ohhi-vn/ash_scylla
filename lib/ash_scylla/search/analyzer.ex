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

  alias AshScylla.Search.Analyzer.{Tokenizer, Normalizer, StopWords, Stemmer}

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
  Analyzes a map of field names to text values.

  Returns a single merged term-frequency list across all fields.
  Each field is analyzed independently and results are merged.

  ## Examples

      iex> Analyzer.analyze_fields(%{
      ...>   title: "Learning Elixir",
      ...>   body: "Elixir is great"
      ...> })
      [{"elixir", 2}, {"learn", 1}, {"great", 1}]
  """
  @spec analyze_fields(%{optional(atom()) => String.t()}, keyword()) :: [{String.t(), pos_integer()}]
  def analyze_fields(fields, opts \\ []) when is_map(fields) do
    fields
    |> Enum.flat_map(fn {_field, text} -> analyze(text, opts) end)
    |> merge_term_frequencies()
  end

  @doc """
  Analyzes a query string for search.

  Unlike document analysis, query analysis preserves the term order
  for phrase search support. Returns a flat list of normalized terms.

  ## Examples

      iex> Analyzer.analyze_query("learning phoenix framework")
      ["learn", "phoenix", "framework"]
  """
  @spec analyze_query(String.t(), keyword()) :: [String.t()]
  def analyze_query(query, opts \\ []) when is_binary(query) do
    stem? = Keyword.get(opts, :stem, true)
    remove_stop? = Keyword.get(opts, :remove_stop_words, true)

    terms = Tokenizer.tokenize(query)

    terms =
      if remove_stop? do
        StopWords.filter(terms)
      else
        terms
      end

    terms = Normalizer.normalize_terms(terms)

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

  defp merge_term_frequencies(term_freqs) do
    term_freqs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {term, freqs} -> {term, Enum.sum(freqs)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end
end
