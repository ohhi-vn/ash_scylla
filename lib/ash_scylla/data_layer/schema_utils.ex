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

defmodule AshScylla.DataLayer.SchemaUtils do
  @moduledoc """
  Shared schema utilities for table names, column analysis, and identifier quoting.

  Centralizes functions that were previously duplicated across
  `AshScylla.DataLayer.SchemaMigration`, `AshScylla.Migration`,
  `AshScylla.DataLayer.MaterializedView`, and `AshScylla.ResourceGenerator`.
  """

  alias AshScylla.DataLayer.Dsl
  alias AshScylla.Identifier

  @doc """
  Returns the table name for a resource.

  Checks the DSL `table/1` config first, then falls back to deriving
  from the module name (using domain prefix if available).
  """
  @spec get_table_name(module()) :: String.t()
  def get_table_name(resource) do
    case Dsl.table(resource) do
      nil ->
        derive_table_name(resource)

      name ->
        to_string(name)
    end
  end

  @doc """
  Quotes a CQL identifier (table name, column name, etc.) for safe use in CQL strings.

  Uses double-quote escaping per CQL spec. Delegates validation to
  `AshScylla.Identifier.validate/1`.
  """
  @spec quote_name(atom() | String.t()) :: String.t() | no_return()
  def quote_name(name) when is_atom(name), do: quote_name(Atom.to_string(name))

  def quote_name(name) when is_binary(name) do
    case Identifier.validate(name) do
      {:ok, _} -> quote_name_unchecked(name)
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  def quote_name(name) do
    raise ArgumentError, "Invalid CQL identifier: expected string or atom, got #{inspect(name)}"
  end

  # Quotes without validation (internal use after validation)
  @spec quote_name_unchecked(String.t()) :: String.t()
  def quote_name_unchecked(name) do
    if String.contains?(name, "\"") do
      escaped = String.replace(name, "\"", "\"\"")
      "\"#{escaped}\""
    else
      "\"#{name}\""
    end
  end

  @doc """
  Returns the list of columns that cannot have secondary indexes.

  Currently this is only the sole partition key column (ScyllaDB forbids it).
  Returns an empty list for composite partition keys or resources without
  a clear single partition key.
  """
  @spec unindexable_columns(module()) :: [atom()]
  def unindexable_columns(resource) do
    try do
      pk_attrs =
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.filter(& &1.primary_key?)

      case pk_attrs do
        [sole_partition_key] -> [sole_partition_key.name]
        _ -> []
      end
    rescue
      # Plain test modules (not Ash resources) have no primary key metadata
      _ -> []
    end
  end

  @doc """
  Resolves a type name for a UDT, sanitizing it for safe CQL interpolation.
  """
  @spec sanitize_type_name(String.t() | atom()) :: String.t()
  def sanitize_type_name(type_name) when is_atom(type_name) do
    type_name |> Atom.to_string() |> sanitize_type_name()
  end

  def sanitize_type_name(type_name) when is_binary(type_name) do
    case Identifier.validate(type_name) do
      {:ok, sanitized} -> sanitized
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  # ---------------------------------------------------------------------------
  # Private functions
  # ---------------------------------------------------------------------------

  defp derive_table_name(resource) do
    segments = Module.split(resource)

    name =
      if Ash.Resource.Info.domain(resource) do
        segments
        |> Enum.take(-2)
        |> Enum.map(&Macro.underscore/1)
        |> Enum.join("_")
      else
        segments
        |> List.last()
        |> Macro.underscore()
      end

    table_attr =
      try do
        Module.get_attribute(resource, :table)
      rescue
        ArgumentError -> nil
      end

    case table_attr do
      nil -> name
      "" -> name
      table -> to_string(table)
    end
  end
end
