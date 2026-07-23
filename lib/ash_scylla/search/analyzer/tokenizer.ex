defmodule AshScylla.Search.Analyzer.Tokenizer do
  @moduledoc """
  Unicode-aware tokenizer for the search pipeline.

  Splits text into individual tokens using Unicode word boundary rules.
  Handles:
    * Mixed scripts (Latin, CJK, etc.)
    * Punctuation stripping
    * Contiguous alphanumeric sequences as single tokens
    * Emoji filtering

  Uses regex patterns that respect Unicode category properties rather
  than simple whitespace splitting.
  """

  @word_pattern ~r/[\p{L}\p{N}][\p{L}\p{N}_]*/u

  @doc """
  Tokenizes a text string into a list of word tokens.

  ## Examples

      iex> Tokenizer.tokenize("Learning Elixir Phoenix Framework")
      ["Learning", "Elixir", "Phoenix", "Framework"]

      iex> Tokenizer.tokenize("Phoenix,Framework!测试")
      ["Phoenix", "Framework", "测试"]

      iex> Tokenizer.tokenize("hello_world test-case")
      ["hello_world", "test", "case"]
  """
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(text) when is_binary(text) do
    Regex.scan(@word_pattern, text)
    |> List.flatten()
  end

  @doc """
  Tokenizes text and returns tokens longer than the minimum length.
  """
  @spec tokenize(String.t(), keyword()) :: [String.t()]
  def tokenize(text, opts) when is_binary(text) do
    min_length = Keyword.get(opts, :min_length, 1)

    tokenize(text)
    |> Enum.filter(&(String.length(&1) >= min_length))
  end

  @doc """
  Tokenizes multiple text fields, returning a flat list of all tokens.
  """
  @spec tokenize_fields(%{optional(atom()) => String.t()}) :: [String.t()]
  def tokenize_fields(fields) when is_map(fields) do
    fields
    |> Enum.flat_map(fn {_field, text} -> tokenize(text) end)
  end
end
