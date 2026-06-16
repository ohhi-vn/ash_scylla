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

defmodule AshScylla.DataLayer.Types do
  @moduledoc """
  Shared CQL type mapping and conversion helpers.

  Centralizes the canonical type-to-CQL-string mappings used across
  `AshScylla.Migration`, `AshScylla.DataLayer.Udt`, and
  `AshScylla.DataLayer.Collection`.
  """

  @cql_type_mapping %{
    # UDT / collection element types
    :text => "TEXT",
    :int => "INT",
    :bigint => "BIGINT",
    :boolean => "BOOLEAN",
    :uuid => "UUID",
    :timestamp => "TIMESTAMP",
    :float => "FLOAT",
    :double => "DOUBLE",
    :blob => "BLOB",
    :binary => "BLOB",
    :inet => "INET",
    :date => "DATE",
    :time => "TIME",
    :smallint => "SMALLINT",
    :tinyint => "TINYINT",
    :duration => "DURATION",
    # Ash DSL type aliases
    :string => "TEXT",
    :integer => "BIGINT",
    :utc_datetime => "TIMESTAMP",
    :utc_datetime_usec => "TIMESTAMP",
    :naive_datetime => "TIMESTAMP",
    :naive_datetime_usec => "TIMESTAMP",
    :decimal => "DECIMAL"
  }

  @doc false
  @spec cql_type_mapping() :: %{atom() => String.t()}
  def cql_type_mapping, do: @cql_type_mapping

  @doc """
  Returns the CQL type string for a given type atom.

  Known types are resolved via the canonical mapping.
  Unknown types fall back to "TEXT".

  ## Examples

      iex> AshScylla.DataLayer.Types.cql_type(:text)
      "TEXT"

      iex> AshScylla.DataLayer.Types.cql_type(:bigint)
      "BIGINT"

      iex> AshScylla.DataLayer.Types.cql_type(:custom_type)
      "TEXT"
  """
  @spec cql_type(atom()) :: String.t()
  def cql_type(type) when is_atom(type) do
    Map.get(@cql_type_mapping, type, "TEXT")
  end

  @doc """
  Returns the CQL type string for a UDT field type atom.

  Delegates to `cql_type/1`.

  ## Examples

      iex> AshScylla.DataLayer.Types.field_type_to_cql(:text)
      "TEXT"

      iex> AshScylla.DataLayer.Types.field_type_to_cql(:uuid)
      "UUID"
  """
  @spec field_type_to_cql(atom()) :: String.t()
  def field_type_to_cql(type), do: cql_type(type)

  @doc """
  Returns the CQL type string for a collection element type atom.

  Delegates to `cql_type/1`.

  ## Examples

      iex> AshScylla.DataLayer.Types.cql_element_type(:int)
      "INT"

      iex> AshScylla.DataLayer.Types.cql_element_type(:float)
      "FLOAT"
  """
  @spec cql_element_type(atom()) :: String.t()
  def cql_element_type(type), do: cql_type(type)

  @doc """
  Returns the list of all known valid CQL type atoms.
  """
  @spec valid_cql_types() :: [atom()]
  def valid_cql_types, do: Map.keys(@cql_type_mapping)

  @doc """
  Converts an Ash type (atom or tuple) to its CQL type string representation.

  Handles special collection and structured types:

  - `:map` — rendered as `MAP<key_type, value_type>`
  - `:array` — rendered as `LIST<element_type>`
  - `:set` — rendered as `SET<element_type>`
  - `:udt` — rendered as `frozen<type_name>`
  - `{:array, element_type}` — rendered as `LIST<cql_type>`
  - `{:map, key_type, value_type}` — rendered as `MAP<k, v>`
  - `{:set, element_type}` — rendered as `SET<cql_type>`

  All other atoms are resolved via the canonical `cql_type/1` mapping.

  The `:frozen` option wraps the result in `frozen<...>`.

  ## Options

  - `:key_type` — for `:map`, the CQL key type (default: `"TEXT"`)
  - `:value_type` — for `:map`, the CQL value type (default: `"TEXT"`)
  - `:element_type` — for `:array` / `:set`, the CQL element type (default: `"TEXT"`)
  - `:type_name` — for `:udt`, the UDT name
  - `:frozen` — if `true`, wraps the result in `frozen<...>`

  ## Examples

      iex> AshScylla.DataLayer.Types.ash_type_to_cql_type(:uuid, [])
      "UUID"

      iex> AshScylla.DataLayer.Types.ash_type_to_cql_type(:string, [])
      "TEXT"

      iex> AshScylla.DataLayer.Types.ash_type_to_cql_type(:map, key_type: "TEXT", value_type: "INT")
      "MAP<TEXT, INT>"

      iex> AshScylla.DataLayer.Types.ash_type_to_cql_type(:array, element_type: "UUID")
      "LIST<UUID>"

      iex> AshScylla.DataLayer.Types.ash_type_to_cql_type({:array, :string}, [])
      "LIST<TEXT>"

      iex> AshScylla.DataLayer.Types.ash_type_to_cql_type({:map, :string, :integer}, [])
      "MAP<TEXT, BIGINT>"
  """
  @spec ash_type_to_cql_type(atom() | tuple(), keyword()) :: String.t()
  def ash_type_to_cql_type(type, opts) when is_atom(type) do
    type = resolve_type(type)

    base_type =
      case type do
        :map ->
          "MAP<#{Keyword.get(opts, :key_type, "TEXT")}, #{Keyword.get(opts, :value_type, "TEXT")}>"

        :array ->
          "LIST<#{Keyword.get(opts, :element_type, "TEXT")}>"

        :set ->
          "SET<#{Keyword.get(opts, :element_type, "TEXT")}>"

        :udt ->
          type_name = Keyword.get(opts, :type_name, "undefined")

          type_name_str =
            if is_atom(type_name), do: Atom.to_string(type_name), else: to_string(type_name)

          "frozen<#{type_name_str}>"

        mapped_type ->
          cql_type(mapped_type)
      end

    if Keyword.get(opts, :frozen), do: "frozen<#{base_type}>", else: base_type
  end

  def ash_type_to_cql_type({:array, element_type}, opts) do
    element_cql = ash_type_to_cql_type(element_type, opts)
    "LIST<#{element_cql}>"
  end

  def ash_type_to_cql_type({:set, element_type}, opts) do
    element_cql = ash_type_to_cql_type(element_type, opts)
    "SET<#{element_cql}>"
  end

  def ash_type_to_cql_type({:map, key_type, value_type}, opts) do
    key_cql = ash_type_to_cql_type(key_type, opts)
    value_cql = ash_type_to_cql_type(value_type, opts)
    "MAP<#{key_cql}, #{value_cql}>"
  end

  def ash_type_to_cql_type({:tuple, element_types}, opts) when is_list(element_types) do
    inner =
      element_types
      |> Enum.map(&ash_type_to_cql_type(&1, opts))
      |> Enum.join(", ")

    "TUPLE<#{inner}>"
  end

  def ash_type_to_cql_type(unknown_type, _opts) do
    require Logger
    Logger.warning("Unknown Ash type #{inspect(unknown_type)}, defaulting to TEXT")
    "TEXT"
  end

  # Resolves Ash type modules (e.g. Ash.Type.UUID) to their short atom names
  # (e.g. :uuid) for CQL type mapping. Uses storage_type/1 when available,
  # otherwise falls back to Ash.Type.Registry lookup. Plain atoms pass through.
  @spec resolve_type(atom()) :: atom()
  defp resolve_type(type) when is_atom(type) do
    cond do
      # Already a plain atom (e.g. :uuid, :string) — pass through
      not match?("Elixir." <> _, Atom.to_string(type)) ->
        type

      # Ash type module with storage_type/1 (e.g. Ash.Type.UUID → :uuid)
      module_loaded?(type) and function_exported?(type, :storage_type, 1) ->
        case type.storage_type([]) do
          storage_type when is_atom(storage_type) ->
            storage_type

          _ ->
            type
        end

      # Fallback: try to find in Ash.Type.Registry by module
      true ->
        find_short_name_by_module(type)
    end
  end

  defp module_loaded?(module) do
    match?({:module, _}, Code.ensure_loaded(module))
  rescue
    _ -> false
  end

  # Looks up a type module in Ash.Type.Registry.short_names() to find its
  # short atom name (e.g. Ash.Type.UUID → :uuid).
  defp find_short_name_by_module(module) do
    Ash.Type.Registry.short_names()
    |> List.keyfind(module, 1)
    |> case do
      {short_name, _module} -> short_name
      nil -> module
    end
  end

  @doc """
  Converts a UUID string (36 chars, e.g. "550e8400-e29b-41d4-a716-446655440000")
  to a 16-byte binary for Xandra/ScyllaDB.

  Returns `{:ok, binary}` on success, `:error` if the string is not a valid UUID.
  """
  @spec uuid_string_to_binary(String.t()) :: {:ok, binary()} | :error
  def uuid_string_to_binary(uuid) when is_binary(uuid) do
    case String.split(uuid, "-") do
      [a, b, c, d, e] when byte_size(uuid) == 36 ->
        hex = a <> b <> c <> d <> e

        case Base.decode16(hex, case: :mixed) do
          {:ok, <<_::16-binary>> = bin} -> {:ok, bin}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def uuid_string_to_binary(_), do: :error

  @doc """
  Converts a 16-byte UUID binary from Xandra/ScyllaDB back to a
  36-character UUID string (e.g. "550e8400-e29b-41d4-a716-446655440000").

  Returns `{:ok, String.t()}` on success, `:error` if the binary is not 16 bytes.
  """
  @spec uuid_binary_to_string(binary()) :: {:ok, String.t()} | :error
  def uuid_binary_to_string(<<a::32, b::16, c::16, d::16, e::48>>) do
    h1 = format_hex(a, 8)
    h2 = format_hex(b, 4)
    h3 = format_hex(c, 4)
    h4 = format_hex(d, 4)
    h5 = format_hex(e, 12)

    {:ok, "#{h1}-#{h2}-#{h3}-#{h4}-#{h5}"}
  end

  def uuid_binary_to_string(_), do: :error

  defp format_hex(value, len) do
    value |> Integer.to_string(16) |> String.pad_leading(len, "0")
  end
end
