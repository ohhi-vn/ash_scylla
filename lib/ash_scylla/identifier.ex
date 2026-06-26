# Copyright [2024] AshScylla Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule AshScylla.Identifier do
  @moduledoc """
  Centralized CQL identifier sanitization.

  All CQL identifiers (table names, column names, keyspace names, index names,
  etc.) MUST be validated through this module before being interpolated into
  CQL strings. This prevents CQL injection attacks.

  ## Valid identifiers

  CQL identifiers must start with a letter or underscore, followed by
  alphanumeric characters or underscores. This matches the regex
  `~r/^[a-zA-Z_][a-zA-Z0-9_]*$/`.

  ## Usage

      iex> AshScylla.Identifier.sanitize!("users")
      "users"

      iex> AshScylla.Identifier.sanitize!("my_table")
      "my_table"

      iex> AshScylla.Identifier.sanitize!("users; DROP TABLE users")
      ** (ArgumentError) Invalid CQL identifier: "users; DROP TABLE users"

  ## Design

  This module is compile-time optimized: `sanitize_identifier/1` is inlined
  and the regex match is compiled once. All public CQL-generating functions
  in AshScylla call this before interpolating identifiers.
  """

  @valid_identifier ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/

  @valid_keyspace_regex ~r/^[a-zA-Z_][a-zA-Z0-9_]{0,47}$/

  @doc """
  Validates that the given string is a safe CQL identifier.

  Returns `{:ok, name}` if valid, or `{:error, reason}` if not.
  """
  @spec validate(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate(name) when is_binary(name) do
    if Regex.match?(@valid_identifier, name) do
      {:ok, name}
    else
      {:error,
       "Invalid CQL identifier: #{inspect(name)}. Identifiers must match #{@valid_identifier.source}"}
    end
  end

  def validate(name) do
    {:error, "Invalid CQL identifier: expected a string, got #{inspect(name)}"}
  end

  @doc """
  Validates that the given value is a safe CQL identifier, raising on failure.

  Accepts both atoms (common in Ash resource definitions) and strings.
  Atoms are converted to strings before validation.

  Returns the sanitized string if valid, raises `ArgumentError` if not.
  """
  @spec sanitize!(atom() | String.t()) :: String.t() | no_return()
  def sanitize!(name) when is_atom(name), do: name |> Atom.to_string() |> sanitize!()

  def sanitize!(name) when is_binary(name) do
    case validate(name) do
      {:ok, name} -> name
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  def sanitize!(name) do
    raise ArgumentError, "Invalid CQL identifier: expected a string, got #{inspect(name)}"
  end

  @doc """
  Returns the regex used to validate keyspace names.
  """
  @spec valid_keyspace_regex() :: Regex.t()
  def valid_keyspace_regex, do: @valid_keyspace_regex

  @doc """
  Validates a keyspace name, raising if invalid.
  """
  @spec validate_keyspace!(String.t() | atom()) :: String.t() | no_return()
  def validate_keyspace!(name) when is_atom(name), do: validate_keyspace!(Atom.to_string(name))

  def validate_keyspace!(name) when is_binary(name) do
    unless Regex.match?(@valid_keyspace_regex, name) do
      raise ArgumentError,
            "Invalid keyspace name: #{inspect(name)}. Keyspace names must match #{@valid_keyspace_regex.source}"
    end

    name
  end

  def validate_keyspace!(name) do
    raise ArgumentError, "Keyspace name must be a string, got: #{inspect(name)}"
  end

  @doc """
  Quotes a CQL identifier for safe interpolation into CQL strings.

  Validates the identifier first, then wraps in double quotes.
  Escapes embedded double quotes by doubling them per CQL spec.

  Returns the quoted string, or raises `ArgumentError` if invalid.

  ## Examples

      iex> AshScylla.Identifier.quote_name("users")
      "\"users\""

      iex> AshScylla.Identifier.quote_name("my table")
      ** (ArgumentError) Invalid CQL identifier: ...
  """
  @spec quote_name(atom() | String.t()) :: String.t() | no_return()
  def quote_name(name) when is_atom(name), do: quote_name(Atom.to_string(name))

  def quote_name(name) when is_binary(name) do
    case validate(name) do
      {:ok, _} -> do_quote_name(name)
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  def quote_name(name) do
    raise ArgumentError, "Invalid CQL identifier: expected string or atom, got #{inspect(name)}"
  end

  @doc false
  @spec do_quote_name(String.t()) :: String.t()
  def do_quote_name(name) do
    if String.contains?(name, "\"") do
      escaped = String.replace(name, "\"", "\"\"")
      "\"#{escaped}\""
    else
      "\"#{name}\""
    end
  end
end
