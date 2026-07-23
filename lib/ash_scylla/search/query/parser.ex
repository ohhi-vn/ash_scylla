defmodule AshScylla.Search.Query.Parser do
  @moduledoc """
  Parses user search queries.

  Handles:
    * Simple word queries: `learning phoenix`
    * AND queries: `learning AND phoenix` or implicit AND between words
    * OR queries: `learning OR phoenix`
    * NOT queries: `phoenix NOT framework`
    * Phrase queries: `"phoenix framework"` (V2)

  Returns a parsed query structure representing the boolean logic.
  """

  defmodule Term do
    @moduledoc false
    defstruct [:word]
    @type t :: %__MODULE__{word: String.t()}
  end

  defmodule Phrase do
    @moduledoc false
    defstruct [:words]
    @type t :: %__MODULE__{words: [String.t()]}
  end

  defmodule Group do
    @moduledoc false
    defstruct [:terms, :op]
    @type t :: %__MODULE__{terms: [struct()], op: :and | :or}
  end

  defmodule NotExpr do
    @moduledoc false
    defstruct [:term]
    @type t :: %__MODULE__{term: struct()}
  end

  @type ast_node :: Term.t() | Phrase.t() | Group.t() | NotExpr.t()

  @doc """
  Parses a query string into a structured representation.

  ## Examples

      iex> Parser.parse("learning phoenix")
      {:ok, %Group{terms: [%Term{word: "learning"}, %Term{word: "phoenix"}], op: :and}}

      iex> Parser.parse("elixir OR phoenix")
      {:ok, %Group{terms: [%Term{word: "elixir"}, %Term{word: "phoenix"}], op: :or}}

      iex> Parser.parse("phoenix NOT framework")
      {:ok, %Group{terms: [%Term{word: "phoenix"}, %NotExpr{term: %Term{word: "framework"}}], op: :and}}
  """
  @spec parse(String.t()) :: {:ok, ast_node()} | {:error, term()}
  def parse(query) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {:error, :empty_query}
    else
      tokens = tokenize_query(query)
      {:ok, parse_tokens(tokens)}
    end
  end

  @spec parse!(String.t()) :: ast_node()
  def parse!(query) do
    case parse(query) do
      {:ok, ast} -> ast
      {:error, reason} -> raise ArgumentError, "Failed to parse query: #{inspect(reason)}"
    end
  end

  defp tokenize_query(query) do
    ~r/"([^"]+)"|[^\s]+/u
    |> Regex.scan(query)
    |> Enum.flat_map(fn
      [_, phrase] when phrase != "" ->
        [{:phrase, phrase}]
      [word] ->
        classify_token(word)
      [word, ""] ->
        classify_token(word)
    end)
  end

  defp classify_token(token) do
    case String.upcase(token) do
      "AND" -> [{:and, nil}]
      "OR" -> [{:or, nil}]
      "NOT" -> [{:not, nil}]
      _ -> [{:word, token}]
    end
  end

  defp parse_tokens(tokens, acc \\ [])
  defp parse_tokens([], acc), do: %Group{terms: Enum.reverse(acc), op: :and}

  defp parse_tokens([{:or, _} | rest], acc) do
    acc_group = %Group{terms: Enum.reverse(acc), op: :and}

    case parse_or_clause(rest, [acc_group]) do
      %Group{terms: _terms, op: :or} = group ->
        combine_implicit_and(group, [])

      single ->
        single
    end
  end

  defp parse_tokens([{:not, _}, {:word, word} | rest], acc) do
    term = %Term{word: word}
    parse_tokens(rest, [%NotExpr{term: term} | acc])
  end

  defp parse_tokens([{:not, _}, {:phrase, phrase} | rest], acc) do
    term = %Phrase{words: String.split(phrase)}
    parse_tokens(rest, [%NotExpr{term: term} | acc])
  end

  defp parse_tokens([{:phrase, phrase} | rest], acc) do
    words = String.split(phrase)
    parse_tokens(rest, [%Phrase{words: words} | acc])
  end

  defp parse_tokens([{:word, word} | rest], acc) do
    parse_tokens(rest, [%Term{word: word} | acc])
  end

  defp parse_tokens([{:and, _} | rest], acc) do
    parse_tokens(rest, acc)
  end

  defp parse_or_clause(tokens, groups) do
    {remaining, last_acc} = parse_until_or(tokens, [])

    new_group = %Group{terms: Enum.reverse(last_acc), op: :and}
    all_groups = groups ++ [new_group]

    case remaining do
      [{:or, _} | rest] -> parse_or_clause(rest, all_groups)
      [] -> %Group{terms: all_groups, op: :or}
      other ->
        remaining_group = %Group{terms: Enum.reverse(other), op: :and}
        %Group{terms: all_groups ++ [remaining_group], op: :or}
    end
  end

  defp parse_until_or([{:or, _} | _] = tokens, acc), do: {tokens, acc}
  defp parse_until_or([], acc), do: {[], acc}

  defp parse_until_or([{:not, _}, {:word, word} | rest], acc) do
    parse_until_or(rest, [%NotExpr{term: %Term{word: word}} | acc])
  end

  defp parse_until_or([{:not, _}, {:phrase, phrase} | rest], acc) do
    parse_until_or(rest, [%NotExpr{term: %Phrase{words: String.split(phrase)}} | acc])
  end

  defp parse_until_or([{:phrase, phrase} | rest], acc) do
    parse_until_or(rest, [%Phrase{words: String.split(phrase)} | acc])
  end

  defp parse_until_or([{:word, word} | rest], acc) do
    parse_until_or(rest, [%Term{word: word} | acc])
  end

  defp parse_until_or([{:and, _} | rest], acc) do
    parse_until_or(rest, acc)
  end

  defp combine_implicit_and(%Group{terms: terms, op: :or}, _acc) do
    combined =
      terms
      |> Enum.map(fn
        %Group{terms: _inner_terms, op: :and} = group ->
          group

        other -> other
      end)

    %Group{terms: combined, op: :or}
  end
end
