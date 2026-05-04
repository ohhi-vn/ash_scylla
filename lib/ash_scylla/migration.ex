defmodule AshScylla.Migration do
  @moduledoc """
  Helpers for working with ScyllaDB migrations using Exandra.

  This module provides utilities to help generate CQL statements for ScyllaDB tables
  based on Ash resource definitions.

  Note: For actual migrations, use Exandra with Ecto.Migration directly.
  See the Exandra documentation for more details on writing migrations.

  ## Example Migration

      defmodule MyApp.Repo.Migrations.CreateUsers do
        use Ecto.Migration

        def change do
          execute "CREATE TABLE users (id UUID PRIMARY KEY, name TEXT, email TEXT)"
        end
      end
  """

  @doc """
  Generates a CQL CREATE TABLE statement for an Ash resource.

  Note: This is a helper that returns a CQL string.
  You need to execute this in an Ecto migration using `execute/1`.
  """
  def create_table_cql(resource) do
    table_name =
      resource
      |> Module.get_attribute(:table)
      |> to_string()
      |> case do
        "" ->
          resource
          |> Module.split()
          |> List.last()
          |> Macro.underscore()

        name ->
          name
      end

    attributes =
      resource
      |> Module.get_attribute(:attributes)
      |> Enum.map(&attribute_to_cql/1)

    primary_keys =
      resource
      |> Module.get_attribute(:attributes)
      |> Enum.filter(fn attr -> Keyword.get(attr, :primary_key) end)
      |> Enum.map(fn attr -> Keyword.get(attr, :name) end)
      |> Enum.join(", ")

    clustering_order = if primary_keys != "" do
      "WITH CLUSTERING ORDER BY (#{primary_keys} DESC)"
    else
      ""
    end

    cql = """
    CREATE TABLE #{table_name} (
      #{Enum.join(attributes, ",\n  ")}
    ) #{clustering_order}
    """

    cql
  end

  @doc """
  Returns the keyspace for a resource if configured via DSL.
  Note: This is a placeholder for future DSL implementation.
  """
  def keyspace(_resource) do
    nil
  end

  @doc """
  Define a User Defined Type (UDT) in ScyllaDB.

  ## Example

      create_type "full_name" do
        field :first_name, :text
        field :last_name, :text
      end

  This generates:
      CREATE TYPE full_name (first_name TEXT, last_name TEXT)
  """
  def create_type(type_name, do: block) do
    fields =
      block
      |> Keyword.new()
      |> Enum.map(fn {name, {type, opts}} ->
        type_str = ash_type_to_cql_type(type, opts)
        "  #{name} #{type_str}"
      end)

    """
    CREATE TYPE IF NOT EXISTS #{type_name} (
    #{Enum.join(fields, ",\n")}
    )
    """
  end

  @doc """
  Drop a User Defined Type (UDt) in ScyllaDB.
  """
  def drop_type(type_name) do
    "DROP TYPE IF EXISTS #{type_name}"
  end

  defp attribute_to_cql(attr) do
    name = Keyword.get(attr, :name)
    type = Keyword.get(attr, :type, :string)
    opts = Keyword.get(attr, :type_opts, [])

    type_str = ash_type_to_cql_type(type, opts)

    primary_key = if Keyword.get(attr, :primary_key), do: " PRIMARY KEY", else: ""
    nullable = unless Keyword.get(attr, :allow_nil, true), do: " NOT NULL", else: ""

    "  #{name} #{type_str}#{primary_key}#{nullable}"
  end

  defp ash_type_to_cql_type(type, opts) when is_atom(type) do
    base_type = case type do
      :uuid -> "UUID"
      :string -> "TEXT"
      :integer -> "BIGINT"
      :boolean -> "BOOLEAN"
      :utc_datetime -> "TIMESTAMP"
      :date -> "DATE"
      :time -> "TIME"
      :map -> "MAP<#{Keyword.get(opts, :key_type, "TEXT")}, #{Keyword.get(opts, :value_type, "TEXT")}>"
      :array -> "LIST<#{Keyword.get(opts, :element_type, "TEXT")}>"
      :set -> "SET<#{Keyword.get(opts, :element_type, "TEXT")}>"
      :udt -> Keyword.get(opts, :type_name, "frozen<undefined>")
      _ -> "TEXT"
    end

    if Keyword.get(opts, :frozen), do: "frozen<#{base_type}>", else: base_type
  end
end
