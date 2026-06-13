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
  """

  @valid_identifier ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/

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
end
