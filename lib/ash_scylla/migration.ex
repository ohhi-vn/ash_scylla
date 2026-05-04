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
    # Get table name from resource module attribute
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
      |> Enum.filter(fn attr -> attr[:primary_key] end)
      |> Enum.map(fn attr -> attr[:name] end)
      |> Enum.join(", ")

    cql = """
    CREATE TABLE #{table_name} (
      #{Enum.join(attributes, ",\n  ")}
    ) WITH CLUSTERING ORDER BY (#{primary_keys} DESC)
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

  defp attribute_to_cql(attr) do
    name = Keyword.get(attr, :name)
    type = Keyword.get(attr, :type, :string)
    primary_key = if Keyword.get(attr, :primary_key), do: " PRIMARY KEY", else: ""
    nullable = unless Keyword.get(attr, :allow_nil, true), do: " NOT NULL", else: ""

    "  #{name} #{ash_type_to_cql_type(type)}#{primary_key}#{nullable}"
  end

  defp ash_type_to_cql_type(type) do
    case type do
      :uuid -> "UUID"
      :string -> "TEXT"
      :integer -> "BIGINT"
      :boolean -> "BOOLEAN"
      :utc_datetime -> "TIMESTAMP"
      :date -> "DATE"
      :time -> "TIME"
      _ -> "TEXT"
    end
  end
end
