defmodule AshScylla.ResourceGenerator do
  @moduledoc """
  Generates starter Ash Resource modules for AshScylla.

  Used by `mix ash_scylla.new_template` to scaffold resource files under
  `lib/<app>/resources/<resource>.ex`.

  ## Arguments

  Accepts a resource name (optionally domain-prefixed) and a comma-separated
  list of `name:type` attribute pairs.

  ## Options

  - `:domain` — Domain module to include in the generated resource
  - `:resource` — Fully-qualified resource module name (overrides positional)
  """

  @resource_name_regex ~r/^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*$/

  @doc """
  Parses generator command arguments.

  Accepts a resource name (optionally domain-prefixed) and a comma-separated
  list of `name:type` attribute pairs.

  ## Examples

      AshScylla.ResourceGenerator.parse_args([
        "MyResource",
        "user_id:uuid, name:string, age:int"
      ])

      AshScylla.ResourceGenerator.parse_args([
        "MyApp.MyDomain.MyResource",
        "user_id:uuid, name:string"
      ])

  Options (as keyword list, passed from the Mix task):

    * `:domain` - Domain module to include in the generated resource
    * `:resource` - Fully-qualified resource module name (overrides the
      positional name argument)
  """
  @spec parse_args([String.t()]) ::
          {:ok, module(), [{atom(), atom()}], keyword()} | {:error, String.t()}
  def parse_args(args) do
    [resource_name | attribute_args] = args

    with {:ok, resource_name} <- validate_resource_name(resource_name),
         {:ok, attributes} <- parse_attributes(attribute_args) do
      {:ok, resource_name, attributes, []}
    end
  rescue
    MatchError ->
      {:error, "Usage: mix ash_scylla.new_template MyResource user_id:uuid, name:string, age:int"}
  end

  @doc """
  Same as `parse_args/1` but also accepts options from CLI flags.

  ## Options

    * `:domain` - Domain module to include in the generated resource
    * `:resource` - Fully-qualified resource module name (overrides positional arg)
  """
  @spec parse_args([String.t()], keyword()) ::
          {:ok, module(), [{atom(), atom()}], keyword()} | {:error, String.t()}
  def parse_args(args, opts) do
    case parse_args(args) do
      {:ok, _resource_name, attributes, _extra_opts} ->
        resource_name = Keyword.get(opts, :resource)
        domain = Keyword.get(opts, :domain)

        resolved_name =
          cond do
            resource_name != nil ->
              {:ok, _} = validate_resource_name(Atom.to_string(resource_name))
              resource_name

            domain != nil ->
              base_name = args |> hd() |> String.to_atom()
              Module.concat(domain, base_name)

            true ->
              args |> hd() |> String.to_atom()
          end

        {:ok, resolved_name, attributes, [domain: domain]}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Writes a generated resource file to `lib/<app>/resources/<resource>.ex`.

  ## Options

    * `:domain` - Domain module to include in the generated resource
    * `:repo_module` - The repo module to reference
  """
  @spec write_resource(module() | String.t(), [{atom(), atom()}], keyword()) :: :ok
  def write_resource(resource_name, attributes, opts \\ []) do
    file_path = resource_file_path(resource_name)
    content = render_resource(resource_name, attributes, opts)

    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, content)

    Mix.shell().info("Generated #{file_path}")

    domain = Keyword.get(opts, :domain)

    next_step =
      if domain do
        "Next: the resource is already configured with domain #{inspect(domain)}."
      else
        "Next: add the resource to your domain and adjust the repo/table if needed."
      end

    Mix.shell().info(next_step)

    :ok
  end

  @doc """
  Returns the generated resource file path for a resource name.
  """
  @spec resource_file_path(module() | String.t()) :: String.t()
  def resource_file_path(resource_name) do
    app_dir = app_name() |> Atom.to_string() |> Macro.underscore()

    file_name =
      resource_name |> to_resource_string() |> last_module_segment() |> Macro.underscore()

    Path.join(["lib", app_dir, "resources", file_name <> ".ex"])
  end

  @doc """
  Renders an Ash Resource template as a string.

  ## Options

    * `:repo_module` - The repo module to reference (defaults to `<AppName>.Repo`)
    * `:domain` - Domain module to include via `domain` option in the resource

  ## Example

      AshScylla.ResourceGenerator.render_resource(
        MyApp.User,
        [user_id: :uuid, name: :string, age: :integer],
        repo_module: MyApp.Repo
      )

      AshScylla.ResourceGenerator.render_resource(
        MyApp.MyDomain.User,
        [user_id: :uuid, name: :string],
        domain: MyApp.MyDomain,
        repo_module: MyApp.Repo
      )
  """
  @spec render_resource(module() | String.t(), [{atom(), atom()}], keyword()) :: String.t()
  def render_resource(resource_name, attributes, opts \\ []) do
    repo_module = Keyword.get(opts, :repo_module) || default_repo_module()
    domain = Keyword.get(opts, :domain)
    module_name = to_module_name(resource_name)
    attributes_block = render_attributes(attributes)

    use_options =
      if domain do
        "  use Ash.Resource,\n    data_layer: AshScylla.DataLayer,\n    repo: #{inspect(repo_module)},\n    domain: #{inspect(domain)}\n"
      else
        "  use Ash.Resource,\n    data_layer: AshScylla.DataLayer,\n    repo: #{inspect(repo_module)}\n"
      end

    """
    defmodule #{module_name} do
    #{use_options}
      attributes do
        uuid_primary_key :id
    #{attributes_block}
      end

      actions do
        defaults [:create, :read, :update, :destroy]
      end
    end
    """
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp parse_attributes(attribute_args) do
    attributes =
      attribute_args
      |> Enum.flat_map(&split_attribute_arg/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_attribute/1)

    if attributes == [] do
      {:error, "At least one attribute is required"}
    else
      {:ok, attributes}
    end
  end

  defp split_attribute_arg(arg) do
    arg
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp parse_attribute(attribute_arg) do
    case String.split(attribute_arg, ":", parts: 2) do
      [name, type] when name != "" and type != "" ->
        {String.to_atom(name), normalize_type(type)}

      _ ->
        Mix.raise(
          "Invalid attribute: #{attribute_arg}. Expected name:type, for example user_id:uuid"
        )
    end
  end

  defp normalize_type(type) do
    case String.to_atom(type) do
      :int -> :integer
      type -> type
    end
  end

  defp validate_resource_name(name) do
    if Regex.match?(@resource_name_regex, name) do
      {:ok, String.to_atom(name)}
    else
      {:error, "Resource name must be an Elixir module alias, for example MyResource"}
    end
  end

  defp render_attributes(attributes) do
    attributes
    |> Enum.reject(fn {name, _type} -> name == :id end)
    |> Enum.map_join("\n", fn {name, type} ->
      "    attribute :#{name}, :#{type}"
    end)
  end

  @doc """
  Renders CQL CREATE TABLE and CREATE INDEX statements for a table.

  Returns a list of CQL statement strings.
  """
  @spec render_create_table(String.t(), [{atom(), atom()}], module()) :: [String.t()]
  def render_create_table(table_name, attributes, _repo_module) do
    table_cql = render_create_table_cql(table_name, attributes)
    index_cqls = render_index_cqls(table_name, attributes)
    [table_cql | index_cqls]
  end

  defp render_create_table_cql(table_name, attributes) do
    {pk_attrs, regular_attrs} =
      Enum.split_with(attributes, fn {_name, type} -> type == :uuid end)

    # Take the first uuid as PK if no explicit PK; otherwise use all non-pk attrs
    {pk_attrs, regular_attrs} =
      case pk_attrs do
        [] ->
          {[], attributes}

        [pk | rest] ->
          {[pk], rest ++ regular_attrs}
      end

    pk_columns =
      pk_attrs
      |> Enum.map(fn {name, type} ->
        "#{name} #{cql_type(type)}"
      end)

    regular_columns =
      regular_attrs
      |> Enum.map(fn {name, type} ->
        "#{name} #{cql_type(type)}"
      end)

    pk_clause =
      case pk_attrs do
        [{name, _type}] ->
          "PRIMARY KEY (#{name})"

        [] ->
          ""
      end

    all_definitions =
      if pk_clause == "" do
        pk_columns ++ regular_columns
      else
        pk_columns ++ regular_columns ++ [pk_clause]
      end

    "CREATE TABLE IF NOT EXISTS #{table_name} (#{Enum.join(all_definitions, ", ")})"
  end

  defp render_index_cqls(table_name, attributes) do
    indexed_columns = [:email, :name, :status, :age]

    attributes
    |> Enum.map(fn {name, _type} -> name end)
    |> Enum.filter(&(&1 in indexed_columns))
    |> Enum.map(fn col ->
      "CREATE INDEX IF NOT EXISTS idx_#{table_name}_#{col} ON #{table_name} (#{col})"
    end)
  end

  defp cql_type(:uuid), do: "UUID"
  defp cql_type(:string), do: "TEXT"
  defp cql_type(:integer), do: "INT"
  defp cql_type(:float), do: "FLOAT"
  defp cql_type(:boolean), do: "BOOLEAN"
  defp cql_type(:date), do: "DATE"
  defp cql_type(:time), do: "TIME"
  defp cql_type(:utc_datetime), do: "TIMESTAMP"
  defp cql_type(:naive_datetime), do: "TIMESTAMP"
  defp cql_type(:binary), do: "BLOB"
  defp cql_type(:map), do: "MAP<TEXT, TEXT>"
  defp cql_type(:list), do: "LIST<TEXT>"
  defp cql_type(_other), do: "TEXT"

  defp default_repo_module do
    app_name()
    |> Atom.to_string()
    |> Macro.camelize()
    |> Kernel.<>(".Repo")
    |> String.to_atom()
  end

  defp app_name do
    case Mix.Project.config()[:app] do
      nil ->
        Mix.raise("Could not determine application name")

      app ->
        app
    end
  end

  defp to_module_name(resource_name) when is_atom(resource_name) do
    resource_name
    |> Atom.to_string()
    |> case do
      "Elixir." <> rest -> rest
      name -> name
    end
  end

  defp to_module_name(resource_name) when is_binary(resource_name) do
    resource_name
  end

  defp to_resource_string(resource_name) when is_atom(resource_name),
    do: Atom.to_string(resource_name)

  defp to_resource_string(resource_name) when is_binary(resource_name), do: resource_name

  defp last_module_segment(resource_name) do
    resource_name
    |> String.split(".")
    |> List.last()
  end
end
