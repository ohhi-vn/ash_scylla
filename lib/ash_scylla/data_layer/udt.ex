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

defmodule AshScylla.DataLayer.Udt do
  @moduledoc """
  User Defined Type (UDT) runtime support for ScyllaDB.

  Handles encoding/decoding UDT values for Xandra,
  CQL generation for UDT operations, and UDT schema management.

  ScyllaDB UDTs are represented as tuples in Xandra. A UDT
  `{field1_val, field2_val}` maps to a map `%{field1: val1, field2: val2}`.
  """

  @type udt_field_spec :: {atom(), atom()}
  @type udt_schema :: %{
          name: atom(),
          type_name: String.t(),
          fields: [udt_field_spec()]
        }

  @doc "Encodes a map value into UDT format for Xandra"
  @spec encode(map(), module()) :: tuple()
  def encode(map, resource) when is_map(map) do
    udt_schemas = resource_udts(resource)

    # Find matching UDT schema by map keys
    field_names = Map.keys(map) |> Enum.sort()

    schema =
      Enum.find(udt_schemas, fn udt_schema ->
        schema_fields = Enum.map(udt_schema.fields, &elem(&1, 0)) |> Enum.sort()
        schema_fields == field_names
      end)

    if schema do
      ordered_values =
        schema.fields
        |> Enum.map(fn {field_name, _type} ->
          Map.get(map, field_name)
        end)

      List.to_tuple(ordered_values)
    else
      # Fallback: encode as tuple in alphabetical order
      map
      |> Map.to_list()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
      |> List.to_tuple()
    end
  end

  @doc "Decodes a UDT tuple from Xandra into a map"
  @spec decode(tuple(), module()) :: map()
  def decode(tuple, resource) when is_tuple(tuple) do
    udt_schemas = resource_udts(resource)
    tuple_values = Tuple.to_list(tuple)

    # Find matching UDT schema by field count
    schema =
      Enum.find(udt_schemas, fn udt_schema ->
        length(udt_schema.fields) == length(tuple_values)
      end)

    if schema do
      schema.fields
      |> Enum.map(fn {field_name, _type} -> field_name end)
      |> Enum.zip(tuple_values)
      |> Map.new()
    else
      # Fallback: create map with positional keys
      tuple_values
      |> Enum.with_index()
      |> Enum.map(fn {val, idx} -> {:"field_#{idx}", val} end)
      |> Map.new()
    end
  end

  @doc "Generates CQL for creating a UDT"
  @spec create_type_cql(String.t() | atom(), [udt_field_spec()]) :: String.t()
  def create_type_cql(type_name, fields) when is_atom(type_name) do
    create_type_cql(Atom.to_string(type_name), fields)
  end

  def create_type_cql(type_name, fields) when is_binary(type_name) do
    fields_cql =
      fields
      |> Enum.map_join(", ", fn {name, type} ->
        "#{name} #{field_type_to_cql(type)}"
      end)

    """
    CREATE TYPE IF NOT EXISTS #{type_name} (
      #{fields_cql}
    )
    """
  end

  @doc "Generates CQL for dropping a UDT"
  @spec drop_type_cql(String.t() | atom()) :: String.t()
  def drop_type_cql(type_name) when is_atom(type_name) do
    drop_type_cql(Atom.to_string(type_name))
  end

  def drop_type_cql(type_name) when is_binary(type_name) do
    "DROP TYPE IF EXISTS #{type_name}"
  end

  @doc "Generates CQL for altering a UDT (add/rename fields)"
  @spec alter_type_cql(String.t() | atom(), :add | :rename, [udt_field_spec()]) :: String.t()
  def alter_type_cql(type_name, :add, fields) when is_atom(type_name) do
    alter_type_cql(Atom.to_string(type_name), :add, fields)
  end

  def alter_type_cql(type_name, :add, fields) when is_binary(type_name) do
    alterations =
      fields
      |> Enum.map_join(", ", fn {name, type} ->
        "ADD #{name} #{field_type_to_cql(type)}"
      end)

    "ALTER TYPE #{type_name} #{alterations}"
  end

  def alter_type_cql(type_name, :rename, renames) when is_atom(type_name) do
    alter_type_cql(Atom.to_string(type_name), :rename, renames)
  end

  def alter_type_cql(type_name, :rename, renames) when is_binary(type_name) do
    alterations =
      renames
      |> Enum.map_join(", ", fn {new_name, old_name} ->
        "RENAME #{old_name} TO #{new_name}"
      end)

    "ALTER TYPE #{type_name} #{alterations}"
  end

  @doc "Generates CQL to list all UDTs in keyspace"
  @spec list_types_cql() :: String.t()
  def list_types_cql do
    "SELECT type_name, field_names, field_types FROM system_schema.types"
  end

  @doc "Generates CQL to check if UDT exists"
  @spec type_exists_cql(String.t() | atom()) :: String.t()
  def type_exists_cql(type_name) when is_atom(type_name) do
    type_exists_cql(Atom.to_string(type_name))
  end

  def type_exists_cql(type_name) when is_binary(type_name) do
    "SELECT type_name FROM system_schema.types WHERE type_name = '#{type_name}'"
  end

  @doc "Returns the CQL type string for a UDT field type"
  @spec field_type_to_cql(atom()) :: String.t()
  def field_type_to_cql(:text), do: "TEXT"
  def field_type_to_cql(:int), do: "INT"
  def field_type_to_cql(:bigint), do: "BIGINT"
  def field_type_to_cql(:boolean), do: "BOOLEAN"
  def field_type_to_cql(:uuid), do: "UUID"
  def field_type_to_cql(:timestamp), do: "TIMESTAMP"
  def field_type_to_cql(:float), do: "FLOAT"
  def field_type_to_cql(:double), do: "DOUBLE"
  def field_type_to_cql(:blob), do: "BLOB"
  def field_type_to_cql(:inet), do: "INET"
  def field_type_to_cql(:date), do: "DATE"
  def field_type_to_cql(:time), do: "TIME"
  def field_type_to_cql(:smallint), do: "SMALLINT"
  def field_type_to_cql(:tinyint), do: "TINYINT"
  def field_type_to_cql(:duration), do: "DURATION"
  def field_type_to_cql(type) when is_atom(type), do: Atom.to_string(type) |> String.upcase()

  @doc "Validates a UDT field specification"
  @spec validate_fields([udt_field_spec()]) :: :ok | {:error, String.t()}
  def validate_fields(fields) when is_list(fields) do
    valid_types = [
      :text,
      :int,
      :bigint,
      :boolean,
      :uuid,
      :timestamp,
      :float,
      :double,
      :blob,
      :inet,
      :date,
      :time,
      :smallint,
      :tinyint,
      :duration
    ]

    Enum.reduce_while(fields, :ok, fn {name, type}, _acc ->
      cond do
        not is_atom(name) ->
          {:halt, {:error, "Field name must be an atom, got: #{inspect(name)}"}}

        not is_atom(type) ->
          {:halt, {:error, "Field type must be an atom, got: #{inspect(type)}"}}

        type not in valid_types ->
          {:halt,
           {:error, "Invalid field type: #{inspect(type)}. Valid types: #{inspect(valid_types)}"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  def validate_fields(_), do: {:error, "Fields must be a list of {name, type} tuples"}

  @doc "Returns all UDTs defined in a resource's attributes"
  @spec resource_udts(module()) :: [udt_schema()]
  def resource_udts(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(fn attr ->
      attr.type == :udt
    end)
    |> Enum.map(fn attr ->
      type_name = get_type_name(attr)
      fields = get_udt_fields(attr)

      %{
        name: attr.name,
        type_name: type_name,
        fields: fields
      }
    end)
  end

  @spec get_type_name(Ash.Resource.Attribute.t()) :: String.t()
  defp get_type_name(attr) do
    opts = attr.constraints
    type_name = Keyword.get(opts, :type_name)

    case type_name do
      nil -> Atom.to_string(attr.name) |> String.upcase()
      name when is_atom(name) -> Atom.to_string(name)
      name when is_binary(name) -> name
    end
  end

  @spec get_udt_fields(Ash.Resource.Attribute.t()) :: [udt_field_spec()]
  defp get_udt_fields(attr) do
    opts = attr.constraints
    fields = Keyword.get(opts, :fields)

    case fields do
      nil -> []
      field_list when is_list(field_list) -> field_list
      _ -> []
    end
  end
end
