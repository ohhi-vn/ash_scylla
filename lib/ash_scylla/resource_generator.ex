defmodule AshScylla.ResourceGenerator do
  @moduledoc """
  Generates starter Ash Resource modules for AshScylla.
  """

  @resource_name_regex ~r/^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*$/

  @doc """
  Parses generator command arguments.

  ## Example

      AshScylla.ResourceGenerator.parse_args([
        "MyResource",
        "user_id:uuid, name:string, age:int"
      ])
  """
  @spec parse_args([String.t()]) :: {:ok, module(), [{atom(), atom()}]} | {:error, String.t()}
  def parse_args(args) do
    [resource_name | attribute_args] = args

    with {:ok, resource_name} <- validate_resource_name(resource_name),
         {:ok, attributes} <- parse_attributes(attribute_args) do
      {:ok, resource_name, attributes}
    end
  rescue
    MatchError ->
      {:error, "Usage: mix ash_scylla.gen MyResource user_id:uuid, name:string, age:int"}
  end

  @doc """
  Writes a generated resource file to `lib/<app>/resources/<resource>.ex`.
  """
  @spec write_resource(module() | String.t(), [{atom(), atom()}]) :: :ok
  def write_resource(resource_name, attributes) do
    file_path = resource_file_path(resource_name)
    content = render_resource(resource_name, attributes, repo_module: default_repo_module())

    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, content)

    Mix.shell().info("Generated #{file_path}")
    Mix.shell().info("Next: add the resource to your domain and adjust the repo/table if needed.")

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

  ## Example

      AshScylla.ResourceGenerator.render_resource(
        MyApp.User,
        [user_id: :uuid, name: :string, age: :integer],
        repo_module: MyApp.Repo
      )
  """
  @spec render_resource(module() | String.t(), [{atom(), atom()}], keyword()) :: String.t()
  def render_resource(resource_name, attributes, opts \\ []) do
    repo_module = Keyword.get(opts, :repo_module) || default_repo_module()
    module_name = to_module_name(resource_name)
    attributes_block = render_attributes(attributes)

    """
    defmodule #{module_name} do
      use Ash.Resource,
        data_layer: AshScylla.DataLayer,
        repo: #{inspect(repo_module)}

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
