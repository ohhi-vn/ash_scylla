defmodule AshScylla.Search.Analyzer.Stemmer do
  @moduledoc """
  A simplified Porter stemming algorithm for English.

  Reduces words to their root form:
    * "running" → "run"
    * "runner"  → "run"
    * "runs"    → "run"

  This is not a full Porter stemmer but covers the most common English
  suffixes. It is good enough for practical search use cases while
  keeping the implementation simple and fast.

  For production use with other languages, consider integrating a
  purpose-built stemming library.
  """

  @doc """
  Stems a single term to its root form.

  Returns the original term unchanged if no stemming rule applies.

  ## Examples

      iex> Stemmer.stem("running")
      "run"

      iex> Stemmer.stem("runs")
      "run"

      iex> Stemmer.stem("easily")
      "easili"

      iex> Stemmer.stem("elixir")
      "elixir"
  """
  @spec stem(String.t()) :: String.t()
  def stem(word) when byte_size(word) <= 2, do: word

  def stem(word) do
    word
    |> step_1a()
    |> step_1b()
    |> step_1c()
    |> step_2()
    |> step_3()
    |> step_4()
    |> step_5a()
    |> step_5b()
  end

  @doc """
  Stems a list of terms, removing duplicates after stemming.
  """
  @spec stem_all([String.t()]) :: [String.t()]
  def stem_all(terms) do
    terms |> Enum.map(&stem/1) |> Enum.uniq()
  end

  # Step 1a: Handle plural and past participle endings
  #   sses  → ss    (caresses → caress)
  #   ies   → i     (ponies → poni)
  #   ss    → ss    (caress → caress)
  #   s     → ""    (cats → cat)

  defp step_1a(word) do
    cond do
      String.ends_with?(word, "sses") -> String.replace_suffix(word, "sses", "ss")
      String.ends_with?(word, "ies") -> String.replace_suffix(word, "ies", "i")
      String.ends_with?(word, "ss") -> word
      String.ends_with?(word, "s") and byte_size(word) > 2 ->
        String.replace_suffix(word, "s", "")
      true -> word
    end
  end

  # Step 1b: Handle -ed and -ing
  #   (m>0) eed  → ee    (feed → feed, agreed → agree)
  #   (v*)  ed   → ""    (plastered → plaster)
  #   (v*)  ing  → ""    (motoring → motor)

  defp step_1b(word) do
    cond do
      String.ends_with?(word, "eed") and byte_size(word) > 3 ->
        stem = String.replace_suffix(word, "eed", "")
        if measure(stem) > 0, do: stem <> "ee", else: word

      String.ends_with?(word, "ed") and contains_vowel?(String.replace_suffix(word, "ed", "")) ->
        stem = String.replace_suffix(word, "ed", "")
        step_1b_extra(stem)

      String.ends_with?(word, "ing") and byte_size(word) > 4 and
          contains_vowel?(String.replace_suffix(word, "ing", "")) ->
        stem = String.replace_suffix(word, "ing", "")
        step_1b_extra(stem)

      String.ends_with?(word, "er") and byte_size(word) > 3 and
          contains_vowel?(String.replace_suffix(word, "er", "")) ->
        stem = String.replace_suffix(word, "er", "")
        step_1b_extra(stem)

      true ->
        word
    end
  end

  defp step_1b_extra(stem) do
    cond do
      String.ends_with?(stem, "at") -> stem <> "e"
      String.ends_with?(stem, "bl") -> stem <> "e"
      String.ends_with?(stem, "iz") -> stem <> "e"
      double_consonant_ending?(stem) and not String.ends_with?(stem, ["l", "s", "z"]) ->
        String.slice(stem, 0..(byte_size(stem) - 2))
      measure(stem) == 1 and cvc_ending?(stem) -> stem <> "e"
      true -> stem
    end
  end

  # Step 1c: Handle -y
  #   (v*) y → i    (happy → happi)

  defp step_1c(word) do
    if String.ends_with?(word, "y") and byte_size(word) > 2 and
         contains_vowel?(String.replace_suffix(word, "y", "")) do
      String.replace_suffix(word, "y", "i")
    else
      word
    end
  end

  # Step 2: Handle double suffixes
  #   ational → ate   (relational → relate)
  #   tional  → tion  (conditional → condition)
  #   enci    → ence  (valenci → valence)
  #   anci    → ance  (hesitanci → hesitance)
  #   izer    → ize   (digitizer → digitize)
  #   abli    → able  (conformabli → conformable)
  #   alli    → al    (radicalli → radical)
  #   entli   → ent   (differentli → different)
  #   eli     → e     (vileli → vile)
  #   ousli   → ous   (analogousli → analogous)
  #   ization → ize   (vietnamization → vietnamize)
  #   ation   → ate   (predication → predicate)
  #   ator    → ate   (operator → operate)
  #   alism   → al    (ationalism → ational)
  #   iveness → ive   (decisiveness → decisive)
  #   fulness → ful   (hopefulness → hopeful)
  #   ousness → ous   (callousness → callous)
  #   aliti   → al    (formalities → formal)
  #   iviti   → ive   (sensitivities → sensitive)
  #   biliti  → ble   (sensibiliti → sensible)

  @step_2_suffixes [
    {"ational", "ate"}, {"tional", "tion"}, {"enci", "ence"},
    {"anci", "ance"}, {"izer", "ize"}, {"abli", "able"},
    {"alli", "al"}, {"entli", "ent"}, {"eli", "e"},
    {"ousli", "ous"}, {"ization", "ize"}, {"ation", "ate"},
    {"ator", "ate"}, {"alism", "al"}, {"iveness", "ive"},
    {"fulness", "ful"}, {"ousness", "ous"}, {"aliti", "al"},
    {"iviti", "ive"}, {"biliti", "ble"}
  ]

  defp step_2(word) do
    Enum.find_value(@step_2_suffixes, word, fn {suffix, replacement} ->
      if String.ends_with?(word, suffix) and byte_size(word) > byte_size(suffix) do
        stem = String.replace_suffix(word, suffix, "")
        if measure(stem) > 0, do: stem <> replacement
      end
    end)
  end

  # Step 3: Handle more suffixes
  @step_3_suffixes [
    {"icate", "ic"}, {"ative", ""}, {"alize", "al"},
    {"iciti", "ic"}, {"ical", "ic"}, {"ful", ""}, {"ness", ""}
  ]

  defp step_3(word) do
    Enum.find_value(@step_3_suffixes, word, fn {suffix, replacement} ->
      if String.ends_with?(word, suffix) and byte_size(word) > byte_size(suffix) do
        stem = String.replace_suffix(word, suffix, "")
        if measure(stem) > 0, do: stem <> replacement
      end
    end)
  end

  # Step 4: Handle deletion suffixes
  @step_4_suffixes ~w(al ance ence er ic able ible ant ement ment ent ism ate iti ous ive ize ion ou)

  defp step_4(word) do
    suffixes = Enum.sort_by(@step_4_suffixes, &byte_size/1, :desc)

    Enum.find_value(suffixes, word, fn suffix ->
      if String.ends_with?(word, suffix) and byte_size(word) > byte_size(suffix) + 1 do
        stem = String.replace_suffix(word, suffix, "")
        if measure(stem) > 1, do: stem
      end
    end)
  end

  # Step 5a: Remove final e
  #   (m>1) e → ""    (probate → probat)
  #   (m=1 and not *o) e → ""  (cease → ceas)

  defp step_5a(word) do
    if String.ends_with?(word, "e") and byte_size(word) > 2 do
      stem = String.replace_suffix(word, "e", "")
      m = measure(stem)
      if m > 1 or (m == 1 and not cvc_ending?(stem)), do: stem, else: word
    else
      word
    end
  end

  # Step 5b: Remove final double l
  #   (m>1) and (*d and *L) → remove last letter

  defp step_5b(word) do
    if measure(word) > 1 and double_consonant_ending?(word) and String.ends_with?(word, "l") do
      String.slice(word, 0..(byte_size(word) - 2))
    else
      word
    end
  end

  # Helpers

  defp measure(word) do
    word
    |> String.graphemes()
    |> Enum.reduce({0, nil}, fn char, {count, last_type} ->
      type = if vowel_char?(char), do: :v, else: :c
      inc = if last_type == :c and type == :v, do: 1, else: 0
      {count + inc, type}
    end)
    |> elem(0)
  end

  defp vowel_char?(<<c::utf8>>) when c in ~c"aeiou", do: true
  defp vowel_char?(<<c::utf8>>) when c in ~c"AEIOU", do: true
  defp vowel_char?(_), do: false

  defp consonant_char?(char), do: not vowel_char?(char)

  defp contains_vowel?(word) do
    String.match?(word, ~r/[aeiouAEIOU]/u)
  end

  defp double_consonant_ending?(word) do
    case String.length(word) do
      len when len >= 2 ->
        a = String.at(word, len - 2)
        b = String.at(word, len - 1)
        a == b and consonant_char?(a)
      _ -> false
    end
  end

  defp cvc_ending?(word) do
    case String.length(word) do
      len when len >= 3 ->
        a = String.at(word, len - 3)
        b = String.at(word, len - 2)
        c = String.at(word, len - 1)
        consonant_char?(a) and vowel_char?(b) and consonant_char?(c) and
          c not in ~w(w x y)
      _ -> false
    end
  end
end
