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

defmodule AshScylla.DataLayer.Codegen do
  @moduledoc """
  Codegen tooling for `mix ash.codegen` / `mix ash_scylla.gen`.

  This module is intentionally separate from `AshScylla.DataLayer`, which
  implements the runtime `Ash.DataLayer` behaviour. None of the functions here
  are part of the runtime data-layer contract — they render CQL `CREATE TABLE`
  / `CREATE INDEX` statements, render migration files, and persist schema-hash
  metadata used for change detection between codegen runs.
  """

  alias AshScylla.DataLayer.Dsl
  alias AshScylla.DataLayer.SchemaUtils
  alias AshScylla.MixHelpers

  @spec codegen(atom(), keyword()) :: {:ok, term()} | {:error, term()}
  def codegen(action, opts) when action in [:dev, :init] do
    resources = MixHelpers.find_all_resources()

    if resources == [] do
      Mix.shell().info("No AshScylla resources found for codegen.")
      {:ok, []}
    else
      repo = MixHelpers.find_default_repo()
      repo_name = repo |> Module.split() |> List.last() |> Macro.underscore()
      migrations_path = Path.join([File.cwd!(), "priv", repo_name, "migrations"])

      # Load previous meta to detect changes
      # Uses the same `.schema_meta` file as `mix ash_scylla.gen` so both commands
      # share change detection state.
      meta_file = Path.join(migrations_path, ".schema_meta")
      previous_meta = load_codegen_meta(meta_file)
      current_meta = compute_codegen_meta(resources)

      force? = Keyword.get(opts, :force, false)

      changed_resources =
        if force? do
          resources
        else
          Enum.filter(resources, fn resource ->
            key = resource_to_key(resource)
            Map.get(previous_meta, key) != Map.get(current_meta, key)
          end)
        end

      if changed_resources == [] do
        Mix.shell().info("Schema is up to date. No changes detected.")
        {:ok, []}
      else
        Mix.shell().info("Generating migrations for #{length(changed_resources)} resource(s)...")

        generated_files =
          Enum.flat_map(changed_resources, fn resource ->
            statements = generate_resource_cql(resource)

            if statements != [""] do
              migration_name = generate_migration_name(resource, action, opts)
              file_path = Path.join(migrations_path, migration_name <> ".ex")
              content = render_migration_file(resource, statements, repo)

              File.mkdir_p!(migrations_path)
              File.write!(file_path, content)

              Mix.shell().info("  Generated #{file_path}")
              [file_path]
            else
              []
            end
          end)

        save_codegen_meta(
          meta_file,
          merge_codegen_meta(previous_meta, changed_resources, current_meta)
        )

        {:ok, generated_files}
      end
    end
  end

  # Generates CQL CREATE TABLE and CREATE INDEX statements for a resource.
  @spec generate_resource_cql(module()) :: [String.t()]
  def generate_resource_cql(resource) do
    table_name = SchemaUtils.get_table_name(resource)
    keyspace = Dsl.keyspace(resource)

    qualified_table_name =
      if keyspace, do: "#{keyspace}.#{table_name}", else: table_name

    indexes = Dsl.secondary_indexes(resource)

    table_cql = AshScylla.Migration.create_table_cql(resource)

    index_cqls =
      indexes
      |> Enum.flat_map(fn idx ->
        idx.columns
        |> Enum.map(fn col ->
          index_name = idx.name || "idx_#{table_name}_#{col}"
          "CREATE INDEX IF NOT EXISTS #{index_name} ON #{qualified_table_name} (#{col})"
        end)
      end)

    [table_cql | index_cqls]
  end

  # Generates a migration file name based on the resource and action.
  @spec generate_migration_name(module(), atom(), keyword()) :: String.t()
  def generate_migration_name(resource, action, opts) do
    resource_name = resource |> Module.split() |> List.last() |> Macro.underscore()

    case action do
      :dev ->
        timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")
        "#{timestamp}_#{resource_name}_dev"

      :init ->
        Keyword.get(opts, :name, "#{resource_name}_init")

      _ ->
        timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")
        "#{timestamp}_#{resource_name}"
    end
  end

  # Renders the migration file content.
  @spec render_migration_file(module(), [String.t()], module()) :: String.t()
  def render_migration_file(resource, statements, _repo) do
    resource_name = resource |> Module.split() |> List.last()
    app = MixHelpers.app_name()
    app_module = app |> Atom.to_string() |> Macro.camelize() |> String.to_atom()
    module_name = Module.concat([app_module, :Migrations, Macro.camelize(resource_name)])

    statements_literal =
      statements
      |> Enum.map_join(",\n", &"  \"#{&1}\"")

    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Migration for #{resource_name}.

      This file was autogenerated with `mix ash.codegen`
      \"\"\"

      use AshScylla.Schema

      @impl AshScylla.Schema
      def change do
    [
    #{statements_literal}
    ]
      end
    end
    """
  end

  # ── Codegen Meta Change Detection ─────────────────────────────────────────

  @doc """
  Computes the meta map for a list of resources.

  Returns a map of resource_key => schema_hash that can be used to detect
  changes between runs.
  """
  @spec compute_codegen_meta([module()]) :: %{String.t() => integer()}
  def compute_codegen_meta(resources) do
    Map.new(resources, fn resource ->
      {resource_to_key(resource), hash_resource_schema(resource)}
    end)
  end

  @doc """
  Filters a list of resources to only those whose schema has changed compared
  to the previous meta map.

  Returns the list of changed resources.
  """
  @spec filter_changed_resources([module()], map()) :: [module()]
  def filter_changed_resources(resources, previous_meta) do
    current_meta = compute_codegen_meta(resources)

    Enum.filter(resources, fn resource ->
      key = resource_to_key(resource)
      Map.get(previous_meta, key) != Map.get(current_meta, key)
    end)
  end

  @doc """
  Merges previous meta with updated entries for changed resources.
  """
  @spec merge_codegen_meta(map(), [module()], map()) :: map()
  def merge_codegen_meta(previous_meta, changed_resources, current_meta) do
    changed_keys = Map.new(changed_resources, &{resource_to_key(&1), true})

    # Start with previous meta, overlay changed resources from current_meta,
    # then add any new resources that exist in current_meta but not in previous_meta.
    # Finally, remove resources that no longer exist in current_meta.
    Map.merge(previous_meta, Map.take(current_meta, Map.keys(changed_keys)))
    |> Map.merge(Map.take(current_meta, Map.keys(current_meta) -- Map.keys(previous_meta)))
    |> Enum.reject(fn {key, _} -> key not in Map.keys(current_meta) end)
    |> Map.new()
  end

  @doc """
  Loads the codegen meta file from disk.

  Returns an empty map if the file doesn't exist or can't be parsed.
  """
  @spec load_codegen_meta(String.t()) :: map()
  def load_codegen_meta(meta_file) do
    case File.read(meta_file) do
      {:ok, content} ->
        case Code.eval_string(content) do
          {map, _} when is_map(map) -> map
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  @doc """
  Saves the codegen meta map to disk.
  """
  @spec save_codegen_meta(String.t(), map()) :: :ok
  def save_codegen_meta(meta_file, meta) do
    File.mkdir_p!(Path.dirname(meta_file))
    File.write!(meta_file, inspect(meta, limit: :infinity, printable_limit: :infinity))
    :ok
  end

  defp resource_to_key(resource), do: inspect(resource)

  defp hash_resource_schema(resource) do
    attributes =
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.sort_by(& &1.name)
      |> Enum.map(fn attr ->
        {attr.name, attr.type, attr.primary_key?, attr.allow_nil?}
      end)

    indexes =
      resource
      |> Dsl.secondary_indexes()
      |> Enum.sort_by(& &1.name)
      |> Enum.map(fn idx ->
        {idx.name, Enum.sort(idx.columns)}
      end)

    :erlang.phash2({attributes, indexes})
  end
end
