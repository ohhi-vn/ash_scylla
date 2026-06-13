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
# WITHOUT REQUIRED WARRANTIES OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule AshScylla.DataLayer.Collection do
  @moduledoc """
  Collection type (LIST, SET, MAP) optimization for ScyllaDB.

  Provides encoding/decoding, CQL generation, and query building
  for ScyllaDB collection types with support for:

  - Frozen collections (immutable, stored as single values)
  - Collection literals in CQL
  - Collection operations (append, prepend, remove, index access)
  - Secondary indexes on collections (for SET/LIST: full collection;
    for MAP: keys, values, or entries)

  ## Usage

      # Encode a list for Xandra
      AshScylla.DataLayer.Collection.encode([1, 2, 3], :list, element_type: :int)

      # Generate CQL for appending to a collection
      AshScylla.DataLayer.Collection.append_cql(:users, :tags, ["new_tag"])

      # Generate a CONTAINS filter
      AshScylla.DataLayer.Collection.contains_cql(:users, :tags, "search_tag")
  """

  @doc """
  Encodes an Elixir collection to Xandra-compatible format.

  ## Options

  - `:element_type` — The type of elements (`:text`, `:int`, `:uuid`, etc.)
  - `:key_type` — For maps, the key type (default: `:text`)
  - `:value_type` — For maps, the value type (default: `:text`)
  - `:frozen` — If true, wrap in a tuple for frozen collections

  ## Examples

      iex> AshScylla.DataLayer.Collection.encode(["a", "b"], :list, element_type: :text)
      ["a", "b"]

      iex> AshScylla.DataLayer.Collection.encode([1, 2, 3], :set, element_type: :int)
      MapSet.new([1, 2, 3])

      iex> AshScylla.DataLayer.Collection.encode(%{"k" => "v"}, :map, key_type: :text, value_type: :text)
      %{"k" => "v"}
  """
  @spec encode(term(), atom(), keyword()) :: term()
  def encode(value, :list, opts) do
    if Keyword.get(opts, :frozen, false) do
      value |> List.to_tuple()
    else
      value
    end
  end

  def encode(value, :set, opts) do
    set = MapSet.new(value)

    if Keyword.get(opts, :frozen, false) do
      set |> MapSet.to_list() |> List.to_tuple()
    else
      set
    end
  end

  def encode(value, :map, opts) when is_map(value) do
    if Keyword.get(opts, :frozen, false) do
      value |> Map.to_list() |> List.to_tuple()
    else
      value
    end
  end

  @doc """
  Decodes a collection from Xandra to Elixir format.

  ## Options

  - `:frozen` — If true, unwrap from tuple format

  ## Examples

      iex> AshScylla.DataLayer.Collection.decode(["a", "b"], :list, [])
      ["a", "b"]

      iex> AshScylla.DataLayer.Collection.decode({1, 2, 3}, :set, frozen: true)
      [1, 2, 3]

      iex> AshScylla.DataLayer.Collection.decode({"k", "v"}, :map, frozen: true)
      %{"k" => "v"}
  """
  @spec decode(term(), atom(), keyword()) :: term()
  def decode(value, :list, opts) do
    if Keyword.get(opts, :frozen, false) do
      Tuple.to_list(value)
    else
      value
    end
  end

  def decode(value, :set, opts) do
    if Keyword.get(opts, :frozen, false) do
      value |> Tuple.to_list()
    else
      value
    end
  end

  def decode(value, :map, opts) do
    if Keyword.get(opts, :frozen, false) do
      value |> Tuple.to_list() |> Map.new()
    else
      value
    end
  end

  @doc """
  Generates CQL for appending to a collection.

  Uses the `+` operator to append elements.

  ## Examples

      iex> AshScylla.DataLayer.Collection.append_cql(:users, :tags, ["new_tag"])
      "UPDATE users SET tags = tags + ? WHERE ..."

      iex> AshScylla.DataLayer.Collection.append_cql("users", :tags, ["new_tag"])
      "UPDATE users SET tags = tags + ? WHERE ..."
  """
  @spec append_cql(String.t() | atom(), atom(), term()) :: String.t()
  def append_cql(table, column, value) when is_atom(table) do
    append_cql(Atom.to_string(table), column, value)
  end

  def append_cql(table, column, _value) when is_binary(table) do
    "UPDATE #{table} SET #{column} = #{column} + ? WHERE ..."
  end

  @doc """
  Generates CQL for prepending to a list.

  Uses the `+` operator with the value on the left side (list prepend).

  ## Examples

      iex> AshScylla.DataLayer.Collection.prepend_cql(:users, :items, ["first"])
      "UPDATE users SET items = ? + items WHERE ..."
  """
  @spec prepend_cql(String.t() | atom(), atom(), term()) :: String.t()
  def prepend_cql(table, column, value) when is_atom(table) do
    prepend_cql(Atom.to_string(table), column, value)
  end

  def prepend_cql(table, column, _value) when is_binary(table) do
    "UPDATE #{table} SET #{column} = ? + #{column} WHERE ..."
  end

  @doc """
  Generates CQL for removing from a collection.

  Uses the `-` operator to remove elements.

  ## Examples

      iex> AshScylla.DataLayer.Collection.remove_cql(:users, :tags, ["old_tag"])
      "UPDATE users SET tags = tags - ? WHERE ..."
  """
  @spec remove_cql(String.t() | atom(), atom(), term()) :: String.t()
  def remove_cql(table, column, value) when is_atom(table) do
    remove_cql(Atom.to_string(table), column, value)
  end

  def remove_cql(table, column, _value) when is_binary(table) do
    "UPDATE #{table} SET #{column} = #{column} - ? WHERE ..."
  end

  @doc """
  Generates CQL for setting a collection element by index/key.

  ## Examples

      iex> AshScylla.DataLayer.Collection.set_at_cql(:users, :items, 0, "first")
      "UPDATE users SET items[?] = ? WHERE ..."

      iex> AshScylla.DataLayer.Collection.set_at_cql(:users, :metadata, "key", "val")
      "UPDATE users SET metadata[?] = ? WHERE ..."
  """
  @spec set_at_cql(String.t() | atom(), atom(), non_neg_integer() | String.t(), term()) ::
          String.t()
  def set_at_cql(table, column, index, value) when is_atom(table) do
    set_at_cql(Atom.to_string(table), column, index, value)
  end

  def set_at_cql(table, column, _index, _value) when is_binary(table) do
    "UPDATE #{table} SET #{column}[?] = ? WHERE ..."
  end

  @doc """
  Generates CQL for accessing a collection element by index/key.

  ## Examples

      iex> AshScylla.DataLayer.Collection.get_at_cql(:users, :items, 0)
      "SELECT items[?] FROM users WHERE ..."

      iex> AshScylla.DataLayer.Collection.get_at_cql(:users, :metadata, "key")
      "SELECT metadata[?] FROM users WHERE ..."
  """
  @spec get_at_cql(String.t() | atom(), atom(), non_neg_integer() | String.t()) :: String.t()
  def get_at_cql(table, column, index) when is_atom(table) do
    get_at_cql(Atom.to_string(table), column, index)
  end

  def get_at_cql(table, column, _index) when is_binary(table) do
    "SELECT #{column}[?] FROM #{table} WHERE ..."
  end

  @doc """
  Generates CQL for getting collection size.

  ## Examples

      iex> AshScylla.DataLayer.Collection.size_cql(:users, :tags)
      "SELECT SIZE(tags) FROM users WHERE ..."
  """
  @spec size_cql(String.t() | atom(), atom()) :: String.t()
  def size_cql(table, column) when is_atom(table) do
    size_cql(Atom.to_string(table), column)
  end

  def size_cql(table, column) when is_binary(table) do
    "SELECT SIZE(#{column}) FROM #{table} WHERE ..."
  end

  @doc """
  Generates CQL for a secondary index on a collection column.

  ## Index Types

  - `:full` — Index the entire frozen collection
  - `:values` — Index individual values in a set or list
  - `:keys` — Index map keys
  - `:entries` — Index map entries as key-value pairs

  ## Examples

      iex> AshScylla.DataLayer.Collection.collection_index_cql(:users, :tags, :values)
      "CREATE INDEX ON users (VALUES(tags))"

      iex> AshScylla.DataLayer.Collection.collection_index_cql(:users, :metadata, :keys)
      "CREATE INDEX ON users (KEYS(metadata))"

      iex> AshScylla.DataLayer.Collection.collection_index_cql(:users, :frozen_data, :full)
      "CREATE INDEX ON users (FULL(frozen_data))"
  """
  @spec collection_index_cql(String.t() | atom(), atom(), :values | :keys | :entries | :full) ::
          String.t()
  def collection_index_cql(table, column, index_type) when is_atom(table) do
    collection_index_cql(Atom.to_string(table), column, index_type)
  end

  def collection_index_cql(table, column, :values) when is_binary(table) do
    "CREATE INDEX ON #{table} (VALUES(#{column}))"
  end

  def collection_index_cql(table, column, :keys) when is_binary(table) do
    "CREATE INDEX ON #{table} (KEYS(#{column}))"
  end

  def collection_index_cql(table, column, :entries) when is_binary(table) do
    "CREATE INDEX ON #{table} (ENTRIES(#{column}))"
  end

  def collection_index_cql(table, column, :full) when is_binary(table) do
    "CREATE INDEX ON #{table} (FULL(#{column}))"
  end

  @doc """
  Generates CQL for a CONTAINS filter (for queries).

  Returns a `{cql_fragment, params}` tuple.

  ## Examples

      iex> AshScylla.DataLayer.Collection.contains_cql(:users, :tags, "admin")
      {"tags CONTAINS ?", ["admin"]}
  """
  @spec contains_cql(String.t() | atom(), atom(), term()) :: {String.t(), [term()]}
  def contains_cql(table, column, value) when is_atom(table) do
    contains_cql(Atom.to_string(table), column, value)
  end

  def contains_cql(_table, column, value) do
    {"#{column} CONTAINS ?", [value]}
  end

  @doc """
  Generates CQL for a CONTAINS KEY filter (for map queries).

  Returns a `{cql_fragment, params}` tuple.

  ## Examples

      iex> AshScylla.DataLayer.Collection.contains_key_cql(:users, :metadata, "role")
      {"metadata CONTAINS KEY ?", ["role"]}
  """
  @spec contains_key_cql(String.t() | atom(), atom(), term()) :: {String.t(), [term()]}
  def contains_key_cql(table, column, value) when is_atom(table) do
    contains_key_cql(Atom.to_string(table), column, value)
  end

  def contains_key_cql(_table, column, value) do
    {"#{column} CONTAINS KEY ?", [value]}
  end

  @doc """
  Returns the CQL type string for a collection type.

  ## Options

  - `:element_type` — Element type for list/set (default: `:text`)
  - `:key_type` — Key type for map (default: `:text`)
  - `:value_type` — Value type for map (default: `:text`)
  - `:frozen` — If true, wrap in `FROZEN<...>`

  ## Examples

      iex> AshScylla.DataLayer.Collection.collection_type_to_cql(:list, element_type: :text)
      "LIST<TEXT>"

      iex> AshScylla.DataLayer.Collection.collection_type_to_cql(:set, element_type: :int)
      "SET<INT>"

      iex> AshScylla.DataLayer.Collection.collection_type_to_cql(:map, key_type: :text, value_type: :int)
      "MAP<TEXT, INT>"

      iex> AshScylla.DataLayer.Collection.collection_type_to_cql(:list, element_type: :text, frozen: true)
      "FROZEN<LIST<TEXT>>"
  """
  @spec collection_type_to_cql(atom(), keyword()) :: String.t()
  def collection_type_to_cql(:list, opts) do
    element_type = cql_element_type(Keyword.get(opts, :element_type, :text))
    inner = "LIST<#{element_type}>"
    maybe_freeze(inner, opts)
  end

  def collection_type_to_cql(:set, opts) do
    element_type = cql_element_type(Keyword.get(opts, :element_type, :text))
    inner = "SET<#{element_type}>"
    maybe_freeze(inner, opts)
  end

  def collection_type_to_cql(:map, opts) do
    key_type = cql_element_type(Keyword.get(opts, :key_type, :text))
    value_type = cql_element_type(Keyword.get(opts, :value_type, :text))
    inner = "MAP<#{key_type}, #{value_type}>"
    maybe_freeze(inner, opts)
  end

  @doc """
  Validates a collection value against its declared type.

  ## Examples

      iex> AshScylla.DataLayer.Collection.validate(["a", "b"], :list, element_type: :text)
      :ok

      iex> AshScylla.DataLayer.Collection.validate("not_a_list", :list, element_type: :text)
      {:error, "Expected a list, got: \"not_a_list\""}
  """
  @spec validate(term(), atom(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, :list, opts) do
    if is_list(value) do
      validate_elements(value, Keyword.get(opts, :element_type, :text))
    else
      {:error, "Expected a list, got: #{inspect(value)}"}
    end
  end

  def validate(value, :set, opts) do
    if is_struct(value, MapSet) or is_list(value) do
      elements = if is_list(value), do: value, else: MapSet.to_list(value)
      validate_elements(elements, Keyword.get(opts, :element_type, :text))
    else
      {:error, "Expected a set, got: #{inspect(value)}"}
    end
  end

  def validate(value, :map, _opts) do
    if is_map(value) do
      :ok
    else
      {:error, "Expected a map, got: #{inspect(value)}"}
    end
  end

  @doc """
  Optimizes a collection value for storage.

  For lists: no change.
  For sets: sorts for consistent encoding.
  For maps: no change.
  For frozen: converts to tuple.

  ## Examples

      iex> AshScylla.DataLayer.Collection.optimize_for_storage([3, 1, 2], :set, element_type: :int)
      [1, 2, 3]

      iex> AshScylla.DataLayer.Collection.optimize_for_storage(["a", "b"], :list, element_type: :text)
      ["a", "b"]
  """
  @spec optimize_for_storage(term(), atom(), keyword()) :: term()
  def optimize_for_storage(value, :set, opts) do
    sorted = Enum.sort(value)

    if Keyword.get(opts, :frozen, false) do
      List.to_tuple(sorted)
    else
      sorted
    end
  end

  def optimize_for_storage(value, :list, opts) do
    if Keyword.get(opts, :frozen, false) do
      List.to_tuple(value)
    else
      value
    end
  end

  def optimize_for_storage(value, :map, opts) do
    if Keyword.get(opts, :frozen, false) do
      value |> Map.to_list() |> List.to_tuple()
    else
      value
    end
  end

  alias AshScylla.DataLayer.Types

  # ---------------------------------------------------------------------------
  # Private functions
  # ---------------------------------------------------------------------------

  @spec cql_element_type(atom()) :: String.t()
  defp cql_element_type(type), do: Types.cql_element_type(type)

  @spec maybe_freeze(String.t(), keyword()) :: String.t()
  defp maybe_freeze(inner, opts) do
    if Keyword.get(opts, :frozen, false) do
      "FROZEN<#{inner}>"
    else
      inner
    end
  end

  @spec validate_elements([term()], atom()) :: :ok | {:error, String.t()}
  defp validate_elements([], _element_type), do: :ok

  defp validate_elements([head | rest], element_type) do
    case validate_element(head, element_type) do
      :ok -> validate_elements(rest, element_type)
      {:error, _} = error -> error
    end
  end

  @spec validate_element(term(), atom()) :: :ok | {:error, String.t()}
  defp validate_element(value, :text) when is_binary(value), do: :ok
  defp validate_element(value, :int) when is_integer(value), do: :ok
  defp validate_element(value, :bigint) when is_integer(value), do: :ok
  defp validate_element(value, :boolean) when is_boolean(value), do: :ok
  defp validate_element(value, :float) when is_float(value), do: :ok
  defp validate_element(value, :double) when is_float(value), do: :ok
  defp validate_element(value, :uuid) when is_binary(value), do: :ok
  defp validate_element(value, :timestamp) when is_integer(value), do: :ok
  defp validate_element(value, :blob) when is_binary(value), do: :ok
  defp validate_element(value, :inet) when is_binary(value), do: :ok
  defp validate_element(value, :date) when is_binary(value), do: :ok
  defp validate_element(value, :time) when is_binary(value), do: :ok
  defp validate_element(value, :smallint) when is_integer(value), do: :ok
  defp validate_element(value, :tinyint) when is_integer(value), do: :ok
  defp validate_element(value, :duration) when is_integer(value), do: :ok

  defp validate_element(value, element_type) do
    {:error, "Element #{inspect(value)} does not match expected type #{inspect(element_type)}"}
  end
end
