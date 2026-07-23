defmodule AshScylla.Search.Analyzer.Normalizer do
  @moduledoc """
  Text normalization for the search pipeline.

  Handles:
    * Lowercasing (Unicode-aware via `String.downcase/2`)
    * Unicode normalization (NFC form)
    * Punctuation and special character removal

  The normalizer runs after tokenization but could also be applied to the
  full text before tokenization.
  """

  @doc """
  Normalizes a single term.

  Applies lowercase, NFC normalization, and strips surrounding punctuation.
  Returns `nil` if the term becomes empty after normalization.

  ## Examples

      iex> Normalizer.normalize_term("Phoenix!")
      "phoenix"

      iex> Normalizer.normalize_term("  ELIXIR  ")
      "elixir"

      iex> Normalizer.normalize_term("!!!")
      nil
  """
  @spec normalize_term(String.t()) :: String.t() | nil
  def normalize_term(term) do
    term
    |> String.trim()
    |> String.downcase()
    |> String.normalize(:nfc)
    |> strip_punctuation()
    |> case do
      "" -> nil
      cleaned -> cleaned
    end
  end

  @doc """
  Normalizes a list of terms, removing any that normalize to `nil` or empty.
  """
  @spec normalize_terms([String.t()]) :: [String.t()]
  def normalize_terms(terms) do
    terms
    |> Enum.map(&normalize_term/1)
    |> Enum.reject(&is_nil/1)
  end

  defp strip_punctuation(text) do
    text
    |> String.replace(~r/^[\p{P}\p{S}]+/u, "")
    |> String.replace(~r/[\p{P}\p{S}]+$/u, "")
    |> String.trim()
  end
end
