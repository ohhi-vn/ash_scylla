defmodule AshScylla.Search.Analyzer.StopWords do
  @moduledoc """
  Stop words filter for the search pipeline.

  Removes common English words that carry little semantic value and would
  otherwise create enormous partitions in the inverted index.

  The stop word list is based on the standard English stop words used by
  Lucene and similar search engines.
  """

  @stop_words MapSet.new([
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "for",
    "if", "in", "into", "is", "it", "no", "not", "of", "on", "or",
    "such", "that", "the", "their", "then", "there", "these", "they",
    "this", "to", "was", "will", "with", "am", "been", "being", "can",
    "could", "did", "do", "does", "doing", "had", "has", "have",
    "having", "he", "her", "here", "hers", "him", "his", "how", "i",
    "its", "just", "let", "may", "me", "might", "my", "nor", "our",
    "ours", "shall", "she", "should", "so", "than", "those", "through",
    "too", "very", "we", "were", "what", "when", "where", "which",
    "who", "whom", "why", "would", "you", "your", "yours", "all",
    "also", "any", "because", "between", "both", "during", "each",
    "few", "from", "further", "more", "most", "once", "only", "other",
    "over", "own", "same", "some", "under", "until", "up", "while"
  ])

  @doc """
  Returns the full set of stop words.
  """
  @spec stop_words() :: MapSet.t()
  def stop_words, do: @stop_words

  @doc """
  Checks if a term is a stop word.
  """
  @spec stop_word?(String.t()) :: boolean()
  def stop_word?(term), do: MapSet.member?(@stop_words, term)

  @doc """
  Removes stop words from a list of terms.
  """
  @spec filter([String.t()]) :: [String.t()]
  def filter(terms) do
    Enum.reject(terms, &stop_word?/1)
  end
end
