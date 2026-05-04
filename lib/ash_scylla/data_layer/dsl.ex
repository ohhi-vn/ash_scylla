defmodule AshScylla.DataLayer.Dsl do
  @moduledoc """
  DSL extensions for configuring ScyllaDB-specific options on Ash resources.

  ## Usage

      defmodule MyApp.MyResource do
        use Ash.Resource,
          data_layer: AshScylla.DataLayer

        ash_scylla do
          table "my_table"
          keyspace "my_keyspace"
          consistency :quorum
          ttl 3600
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
        end
      end

  ## Options

  - `:table` - The table name in ScyllaDB (overrides default)
  - `:keyspace` - The keyspace to use (overrides repo default)
  - `:consistency` - The consistency level for reads/writes
  - `:ttl` - Default TTL for inserted records (in seconds)
  """

  @doc """
  Macro for configuring ScyllaDB options in Ash resources.

  ## Examples

      ash_scylla do
        table "users"
        keyspace "my_keyspace"
        consistency :quorum
        ttl 3600
      end
  """
  defmacro ash_scylla(do: block) do
    quote do
      unquote(block)
      |> Keyword.new()
      |> Enum.each(fn
        {:table, val} ->
          @ash_scylla_table val

        {:keyspace, val} ->
          @ash_scylla_keyspace val

        {:consistency, val} ->
          @ash_scylla_consistency val

        {:ttl, val} ->
          @ash_scylla_ttl val

        other ->
          raise "Unknown ash_scylla option: #{inspect(other)}"
      end)

      # Generate getter functions at compile time
      def __ash_scylla__(:table), do: Module.get_attribute(__MODULE__, :ash_scylla_table)
      def __ash_scylla__(:keyspace), do: Module.get_attribute(__MODULE__, :ash_scylla_keyspace)
      def __ash_scylla__(:consistency), do: Module.get_attribute(__MODULE__, :ash_scylla_consistency)
      def __ash_scylla__(:ttl), do: Module.get_attribute(__MODULE__, :ash_scylla_ttl)
      def __ash_scylla__(_opt), do: nil
    end
  end

  @doc """
  Gets the configured table name for a resource.
  """
  def table(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:table)
    else
      nil
    end
  end

  @doc """
  Gets the configured keyspace for a resource.
  """
  def keyspace(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:keyspace)
    else
      nil
    end
  end

  @doc """
  Gets the configured consistency level for a resource.
  """
  def consistency(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:consistency)
    else
      nil
    end
  end

  @doc """
  Gets the configured TTL for a resource.
  """
  def ttl(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:ttl)
    else
      nil
    end
  end
end
