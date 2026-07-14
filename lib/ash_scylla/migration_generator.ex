# Copyright 2024 AshScylla Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule AshScylla.MigrationGenerator do
  @moduledoc """
  Generates CQL migration files from Ash resource definitions.

  Compares current Ash resource snapshots against the live ScyllaDB schema
  and generates CQL statements to bring the schema in sync.

  ## Usage

      # Generate a migration for all resources
      mix ash_scylla.generate_migrations

      # Generate with a specific name
      mix ash_scylla.generate_migrations add_user_table

      # Dry run (print without creating files)
      mix ash_scylla.generate_migrations --dry-run

      # Check if migrations are needed (exit code 1 if so)
      mix ash_scylla.generate_migrations --check

  ## Snapshots

  Snapshots are stored in `priv/repo_name/resource_snapshots/` as JSON files.
  Each snapshot captures the state of a resource's schema at a point in time.
  The migration generator compares the current resource definition against the
  most recent snapshot to determine what changes need to be made.
  """

  alias AshScylla.DataLayer.Dsl
  alias AshScylla.DataLayer.SchemaUtils
  alias AshScylla.Migration

  defstruct snapshot_path: nil,
            migration_path: nil,
            name: nil,
            domains: nil,
            quiet: false,
            format: true,
            dry_run: false,
            check: false,
            dev: false,
            snapshots_only: false

  @doc """
  Main entry point for migration generation.

  Options:
    - `:domains` - list of domains to generate for (defaults to all configured)
    - `:snapshot_path` - custom path for snapshots (default: `priv/repo/resource_snapshots`)
    - `:migration_path` - custom path for migrations (default: `priv/repo/migrations`)
    - `:name` - name for the migration (auto-generated if not provided)
    - `:quiet` - suppress output
    - `:format` - format generated Elixir code (default: true)
    - `:dry_run` - print migrations without creating files
    - `:check` - return exit code 1 if migrations needed
    - `:dev` - create dev migrations (suffixed with `_dev`)
    - `:snapshots_only` - only create snapshots, no migration files
  """
  def generate(opts \\ []) do
    opts = struct(__MODULE__, opts)

    resources = find_resources(opts)

    if resources == [] do
      Mix.shell().info("No AshScylla resources found.")
      :ok
    else
      {migration_files, snapshot_files} = generate_migrations(resources, opts)

      case {migration_files, snapshot_files} do
        {[], []} ->
          if !opts.check || opts.dry_run do
            Mix.shell().info(
              "No changes detected, so no migrations or snapshots have been created."
            )
          end

          :ok

        {files, snapshots} ->
          all_files = files ++ snapshots

          cond do
            opts.check ->
              raise Ash.Error.Framework.PendingCodegen,
                diff: all_files

            opts.dry_run ->
              migration_files =
                Enum.filter(all_files, fn {file, _contents} ->
                  String.ends_with?(file, ".exs")
                end)

              snapshot_files =
                Enum.filter(all_files, fn {file, _contents} ->
                  String.ends_with?(file, ".json")
                end)

              if migration_files != [] do
                Mix.shell().info(
                  "Migrations generated for #{length(migration_files)} resource(s):"
                )

                Enum.each(migration_files, fn {file, contents} ->
                  Mix.shell().info("""
                  --- #{Path.basename(file)} ---
                  #{String.replace(contents, "\n", "\n  ")}
                  """)
                end)
              end

              if snapshot_files != [] do
                Mix.shell().info(
                  "Resource snapshots generated for #{length(snapshot_files)} resource(s)."
                )

                Enum.each(snapshot_files, fn {file, _contents} ->
                  Mix.shell().info("  Snapshot: #{file}")
                end)
              end

            true ->
              Enum.each(all_files, fn {file, contents} ->
                Mix.Generator.create_file(file, contents, force: true)
              end)
          end
      end
    end
  end

  @doc """
  Takes snapshots of the given resources without generating migrations.
  Useful for initial setup.
  """
  def take_snapshots(opts \\ []) do
    opts = %{struct(__MODULE__, opts) | snapshots_only: true}
    generate(opts)
  end

  # ── Resource Discovery ───────────────────────────────────────────────────

  defp find_resources(%{domains: domains}) when is_list(domains) and length(domains) > 0 do
    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&ash_scylla_resource?/1)
    |> Enum.uniq()
  end

  defp find_resources(_opts) do
    AshScylla.MixHelpers.find_all_resources()
  end

  defp ash_scylla_resource?(resource) do
    Ash.Resource.Info.data_layer(resource) == AshScylla.DataLayer
  rescue
    _ -> false
  end

  # Falls back to extracting the repo from the first resource's DSL config
  # when find_default_repo raises (e.g. when the application isn't started).
  defp fallback_repo(resources) do
    resources
    |> Enum.map(&AshScylla.DataLayer.Dsl.repo/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [repo | _] ->
        repo

      [] ->
        Mix.raise("No repo found. Configure a repo on your resources or start the application.")
    end
  end

  # ── Migration Generation ─────────────────────────────────────────────────

  defp generate_migrations(resources, opts) do
    repo =
      try do
        AshScylla.MixHelpers.find_default_repo()
      rescue
        Mix.Error -> fallback_repo(resources)
      end

    repo_name = repo_name(repo)

    migration_path = migration_path(opts, repo)
    snapshot_path = snapshot_path(opts, repo)

    # Group resources by table to detect conflicts
    {managed_resources, _unmanaged_resources} =
      Enum.split_with(resources, &AshScylla.DataLayer.Dsl.migrate?/1)

    # Warn when multiple resources resolve to the same table name, which would
    # cause conflicting DDL (two CREATE TABLE statements for a single table).
    managed_resources
    |> Enum.group_by(&SchemaUtils.get_table_name/1)
    |> Enum.filter(fn {_table, rs} -> length(rs) > 1 end)
    |> Enum.each(fn {table, rs} ->
      Mix.shell().info(
        "Warning: multiple resources map to table #{table}: " <>
          Enum.map_join(rs, ", ", &inspect/1)
      )
    end)

    # Get existing snapshots from disk
    existing_snapshots = load_existing_snapshots(snapshot_path, repo_name)

    # Compute diffs for each resource
    {migration_files, snapshot_files} =
      managed_resources
      |> Enum.reduce({[], []}, fn resource, {mig_acc, snap_acc} ->
        {operations, new_snapshot} = diff_resource(resource, existing_snapshots, repo)

        resource_key = resource_snapshot_key(resource)

        # Only write a new snapshot if there are actual changes or no previous snapshot existed.
        # This prevents re-generating snapshot files on every run when schema hasn't changed.
        snapshot_file =
          if operations != [] || !Map.has_key?(existing_snapshots, resource_key) do
            write_snapshot(snapshot_path, repo_name, resource_key, new_snapshot, opts)
          else
            # No changes - skip writing a new snapshot file
            nil
          end

        # Generate migration if there are operations
        migration_file =
          if operations != [] && !opts.snapshots_only do
            [generate_migration(resource, operations, migration_path, opts)]
          else
            []
          end

        snapshot_acc = if snapshot_file, do: snap_acc ++ [snapshot_file], else: snap_acc
        {mig_acc ++ migration_file, snapshot_acc}
      end)

    {migration_files, snapshot_files}
  end

  # ── Snapshot Management ──────────────────────────────────────────────────

  # Returns a unique key for a resource used to name and look up its snapshot
  # file. Uses the full module path (e.g. "my_app.domain_a.user") so that two
  # resources with the same short name in different domains do not collide.
  defp resource_snapshot_key(resource) do
    resource
    |> Module.split()
    |> Enum.map_join(".", &Macro.underscore/1)
  end

  defp load_existing_snapshots(snapshot_path, repo_name) do
    snapshot_dir = Path.join(snapshot_path, repo_name)

    if File.dir?(snapshot_dir) do
      snapshot_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(fn file ->
        path = Path.join(snapshot_dir, file)
        json = File.read!(path)
        data = Jason.decode!(json)

        # Key by the full resource module path when present (unique across
        # domains); fall back to the table name for snapshots written by older
        # versions of this generator.
        {data["resource"] || data["table"], data}
      end)
      |> Map.new()
    else
      %{}
    end
  end

  defp write_snapshot(snapshot_path, repo_name, resource_name, snapshot_data, opts) do
    snapshot_dir = Path.join(snapshot_path, repo_name)

    if !opts.dry_run && !opts.check do
      File.mkdir_p!(snapshot_dir)
    end

    dev_suffix = if opts.dev, do: "_dev", else: ""

    snapshot_file =
      Path.join(snapshot_dir, "#{resource_name}#{dev_suffix}.json")

    snapshot_json =
      snapshot_data
      |> Jason.encode!(pretty: true)

    if !opts.dry_run && !opts.check do
      File.write!(snapshot_file, snapshot_json)
    end

    {snapshot_file, snapshot_json}
  end

  # ── Diffing ──────────────────────────────────────────────────────────────

  defp diff_resource(resource, existing_snapshots, repo) do
    table_name = SchemaUtils.get_table_name(resource)
    resource_key = resource_snapshot_key(resource)
    current_attrs = Ash.Resource.Info.attributes(resource)
    current_indexes = Dsl.secondary_indexes(resource)

    # Find existing snapshot for this resource. Keyed by the full resource
    # module path (unique across domains); fall back to the table name for
    # snapshots written by older versions of this generator.
    existing =
      case Map.get(existing_snapshots, resource_key) do
        nil ->
          Map.get(existing_snapshots, table_name)

        snapshot ->
          snapshot
      end

    existing =
      case existing do
        nil ->
          nil

        snapshot ->
          # Normalize string keys from JSON to atoms
          %{
            "table" => snapshot["table"],
            "attributes" => snapshot["attributes"],
            "indexes" => snapshot["indexes"]
          }
      end

    operations = compute_operations(resource, existing, current_attrs, current_indexes, repo)

    new_snapshot = %{
      "resource" => resource_key,
      "table" => table_name,
      "attributes" =>
        current_attrs
        |> Enum.sort_by(& &1.name)
        |> Enum.map(fn attr ->
          %{
            "name" => attr.name |> to_string(),
            "type" => inspect(attr.type),
            "source" => (attr.source || attr.name) |> to_string(),
            "primary_key?" => attr.primary_key?,
            "allow_nil?" => attr.allow_nil?
          }
        end),
      "indexes" =>
        current_indexes
        |> Enum.sort_by(& &1.name)
        |> Enum.map(fn idx ->
          %{
            "name" => idx.name |> to_string(),
            "columns" => Enum.sort(idx.columns |> Enum.map(&to_string/1))
          }
        end)
    }

    {operations, new_snapshot}
  end

  defp compute_operations(resource, existing, current_attrs, current_indexes, _repo) do
    table_name = SchemaUtils.get_table_name(resource)

    existing_attrs = existing["attributes"] || []
    existing_indexes = existing["indexes"] || []

    # Build maps for easy lookup
    existing_attr_names =
      existing_attrs
      |> Enum.map(&String.to_atom(&1["name"]))
      |> MapSet.new()

    current_attr_names =
      current_attrs
      |> Enum.map(& &1.name)
      |> MapSet.new()

    existing_index_names =
      existing_indexes
      |> Enum.map(&normalize_index_name(&1["name"]))
      |> MapSet.new()

    current_index_names =
      current_indexes
      |> Enum.map(&normalize_index_name(&1.name))
      |> MapSet.new()

    # Determine what needs to be added
    attrs_to_add =
      current_attr_names
      |> MapSet.difference(existing_attr_names)
      |> MapSet.to_list()

    attrs_to_remove =
      existing_attr_names
      |> MapSet.difference(current_attr_names)
      |> MapSet.to_list()

    indexes_to_add =
      current_index_names
      |> MapSet.difference(existing_index_names)
      |> MapSet.to_list()

    indexes_to_remove =
      existing_index_names
      |> MapSet.difference(current_index_names)
      |> MapSet.to_list()

    # If no existing snapshot, this is a new table
    operations =
      if existing == nil do
        # Generate CREATE TABLE
        [
          {:create_table, table_name,
           %{
             attributes: current_attrs,
             primary_key: Enum.filter(current_attrs, & &1.primary_key?)
           }}
        ]
      else
        # Generate ALTER TABLE ADD for new columns
        add_ops =
          if attrs_to_add != [] do
            [
              {:add_attributes, table_name,
               %{
                 attributes:
                   current_attrs
                   |> Enum.filter(&(&1.name in attrs_to_add))
               }}
            ]
          else
            []
          end

        # Generate ALTER TABLE DROP for removed columns (commented by default)
        remove_ops =
          if attrs_to_remove != [] do
            [
              {:remove_attributes, table_name,
               %{
                 attributes:
                   existing_attrs
                   |> Enum.filter(&(&1["name"] in attrs_to_remove))
                   |> Enum.map(&String.to_atom(&1["name"]))
               }}
            ]
          else
            []
          end

        add_ops ++ remove_ops
      end

    # Generate CREATE INDEX for new indexes
    index_add_ops =
      if indexes_to_add != [] do
        new_indexes = current_indexes |> Enum.filter(&(&1.name in indexes_to_add))

        [
          {:add_indexes, table_name,
           %{
             indexes: new_indexes
           }}
        ]
      else
        []
      end

    # Generate DROP INDEX for removed indexes
    index_remove_ops =
      if indexes_to_remove != [] do
        [
          {:remove_indexes, table_name,
           %{
             index_names:
               existing_indexes
               |> Enum.filter(&(&1["name"] in indexes_to_remove))
               |> Enum.map(&String.to_atom(&1["name"]))
           }}
        ]
      else
        []
      end

    operations ++ index_add_ops ++ index_remove_ops
  end

  # Normalizes index names for comparison.
  # Converts nil and "" to a common representation so that indexes without
  # custom names are treated as equal.
  defp normalize_index_name(name) when is_binary(name), do: if(name == "", do: nil, else: name)
  defp normalize_index_name(name), do: name

  # ── Migration File Rendering ─────────────────────────────────────────────

  defp generate_migration(resource, operations, migration_path, opts) do
    table_name = SchemaUtils.get_table_name(resource)
    resource_key = resource_snapshot_key(resource)

    require_name!(opts)

    {migration_name, last_part} =
      if opts.name do
        # A fixed `--name` (e.g. `mix ash_scylla.generate_migrations new`) must
        # still be made unique per resource, otherwise every generated file
        # would share the same module name (AshScylla.Migrations.New) and
        # collide at load time. Append the resource key and a per-run counter.
        run_count =
          Process.get(:ash_scylla_migration_run_count, 0)

        Process.put(:ash_scylla_migration_run_count, run_count + 1)

        safe_key = String.replace(resource_key, ".", "_")

        {
          "#{timestamp()}_#{opts.name}_#{safe_key}_#{run_count + 1}",
          "#{Macro.camelize(opts.name)}_#{safe_key}_#{run_count + 1}"
        }
      else
        # Count existing migration files on disk, plus any generated earlier in
        # this run (tracked in the process dictionary) so that multiple
        # resources processed in a single invocation each get a distinct name.
        count =
          migration_path
          |> Path.join("*_migrate_*")
          |> Path.wildcard()
          |> length()

        run_count =
          Process.get(:ash_scylla_migration_run_count, 0)

        Process.put(:ash_scylla_migration_run_count, run_count + 1)

        # Sanitize the resource key (which may contain dots) into a single
        # underscore-delimited token so the migration module name and file
        # name stay valid and collision-free across domains.
        safe_key = String.replace(resource_key, ".", "_")

        {
          "#{timestamp()}_migrate_#{safe_key}_#{count + run_count + 1}",
          "migrate_#{safe_key}_#{count + run_count + 1}"
        }
      end

    migration_file =
      migration_path
      |> Path.join(migration_name <> "#{if opts.dev, do: "_dev"}.exs")

    module_name = Module.concat([:AshScylla, :Migrations, Macro.camelize(last_part)])

    # Generate CQL statements from operations
    {up_statements, _down_statements} = render_operations(operations, resource)

    contents = """
    defmodule #{inspect(module_name)} do
      @moduledoc \"\"\"
      Migration for #{table_name}.

      This file was autogenerated with `mix ash_scylla.generate_migrations`
      \"\"\"

      use AshScylla.Schema

      @impl AshScylla.Schema
      def change do
    [
    #{render_cql_statements(up_statements)}
    ]
      end
    end
    """

    contents = format(migration_file, contents, opts)

    {migration_file, contents}
  end

  defp render_cql_statements(statements) do
    statements
    |> Enum.map(fn stmt -> "    \"#{escape_cql(stmt)}\"" end)
    |> Enum.join(",\n")
  end

  defp escape_cql(cql) do
    cql
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp render_operations(operations, resource) do
    up = Enum.flat_map(operations, &render_operation_up(&1, resource))
    down = Enum.flat_map(operations, &render_operation_down(&1, resource))
    {up, down}
  end

  defp render_operation_up({:create_table, table_name, config}, _resource) do
    attrs = config[:attributes]
    {pk_attrs, regular_attrs} = Enum.split_with(attrs, & &1.primary_key?)

    pk_columns =
      pk_attrs
      |> Enum.map(fn attr ->
        type_str = Migration.ash_type_to_cql_type(attr.type, attr.constraints)
        "#{AshScylla.Identifier.quote_name(attr.name)} #{type_str}"
      end)

    regular_columns =
      regular_attrs
      |> Enum.map(fn attr ->
        type_str = Migration.ash_type_to_cql_type(attr.type, attr.constraints)
        "#{AshScylla.Identifier.quote_name(attr.name)} #{type_str}"
      end)

    pk_clause =
      case pk_attrs do
        [single_pk] ->
          "PRIMARY KEY (#{AshScylla.Identifier.quote_name(single_pk.name)})"

        [partition_key | clustering_keys] ->
          pk_cols = [partition_key.name | Enum.map(clustering_keys, & &1.name)]
          "PRIMARY KEY (#{Enum.map_join(pk_cols, ", ", &AshScylla.Identifier.quote_name/1)})"

        [] ->
          ""
      end

    all_definitions =
      if pk_clause == "" do
        pk_columns ++ regular_columns
      else
        pk_columns ++ regular_columns ++ [pk_clause]
      end

    [
      "CREATE TABLE IF NOT EXISTS #{quote_table_name(table_name)} (#{Enum.join(all_definitions, ", ")})"
    ]
  end

  defp render_operation_up({:add_attributes, table_name, config}, _resource) do
    attrs = config[:attributes]

    attrs
    |> Enum.map(fn attr ->
      type_str = Migration.ash_type_to_cql_type(attr.type, attr.constraints)

      "ALTER TABLE #{quote_table_name(table_name)} ADD #{AshScylla.Identifier.quote_name(attr.name)} #{type_str}"
    end)
  end

  defp render_operation_up({:remove_attributes, table_name, config}, _resource) do
    attrs = config[:attributes]

    attrs
    |> Enum.map(fn attr ->
      "# ALTER TABLE #{quote_table_name(table_name)} DROP #{AshScylla.Identifier.quote_name(attr.name)}"
    end)
  end

  defp render_operation_up({:add_indexes, table_name, config}, _resource) do
    indexes = config[:indexes]

    Enum.flat_map(indexes, fn idx ->
      idx.columns
      |> Enum.map(fn col ->
        index_name =
          if idx.name do
            "#{idx.name}_#{col}"
          else
            "idx_#{table_name}_#{col}"
          end

        "CREATE INDEX IF NOT EXISTS #{index_name} ON #{quote_table_name(table_name)} (#{AshScylla.Identifier.quote_name(col)})"
      end)
    end)
  end

  defp render_operation_up({:remove_indexes, _table_name, config}, _resource) do
    index_names = config[:index_names]

    index_names
    |> Enum.map(fn name ->
      "# DROP INDEX IF EXISTS #{name}"
    end)
  end

  defp render_operation_up(_, _resource), do: []

  defp render_operation_down({:create_table, table_name, _config}, _resource) do
    ["# DROP TABLE IF EXISTS #{quote_table_name(table_name)}"]
  end

  defp render_operation_down({:add_attributes, table_name, config}, _resource) do
    attrs = config[:attributes]

    attrs
    |> Enum.map(fn attr ->
      "ALTER TABLE #{quote_table_name(table_name)} DROP #{AshScylla.Identifier.quote_name(attr.name)}"
    end)
  end

  defp render_operation_down({:remove_attributes, table_name, config}, _resource) do
    attrs = config[:attributes]

    attrs
    |> Enum.map(fn attr ->
      "# ALTER TABLE #{quote_table_name(table_name)} ADD #{AshScylla.Identifier.quote_name(attr.name)} <type>"
    end)
  end

  defp render_operation_down({:add_indexes, table_name, config}, _resource) do
    indexes = config[:indexes]

    Enum.flat_map(indexes, fn idx ->
      idx.columns
      |> Enum.map(fn col ->
        index_name =
          if idx.name do
            "#{idx.name}_#{col}"
          else
            "idx_#{table_name}_#{col}"
          end

        "DROP INDEX IF EXISTS #{index_name}"
      end)
    end)
  end

  defp render_operation_down({:remove_indexes, table_name, config}, _resource) do
    index_names = config[:index_names]

    index_names
    |> Enum.map(fn name ->
      "# CREATE INDEX IF NOT EXISTS #{name} ON #{quote_table_name(table_name)} (<columns>)"
    end)
  end

  defp render_operation_down(_, _resource), do: []

  # ── CQL Helpers ─────────────────────────────────────────────────────────

  # Quotes a table name for CQL. When the table name contains a keyspace
  # prefix (e.g. "keyspace.table"), quotes each part separately to produce
  # valid CQL: "keyspace"."table". This also avoids generating invalid
  # Elixir string syntax in migration files.
  defp quote_table_name(table_name) do
    case String.split(table_name, ".") do
      [single] -> "\"#{single}\""
      [keyspace, table] -> "\"#{keyspace}\".\"#{table}\""
      parts -> Enum.map_join(parts, ".", &"\"#{&1}\"")
    end
  end

  # ── Path Helpers ─────────────────────────────────────────────────────────

  defp migration_path(opts, repo) do
    config = repo.config()

    case opts.migration_path || config[:migrations_path] do
      nil ->
        repo_name = repo |> Module.split() |> List.last() |> Macro.underscore()
        Path.join(["priv", repo_name, "migrations"])

      path ->
        path
    end
  end

  defp snapshot_path(opts, repo) do
    config = repo.config()

    case opts.snapshot_path || config[:snapshots_path] do
      nil ->
        repo_name = repo |> Module.split() |> List.last() |> Macro.underscore()
        Path.join(["priv", repo_name, "resource_snapshots"])

      path ->
        path
    end
  end

  defp repo_name(repo) do
    repo |> Module.split() |> List.last() |> Macro.underscore()
  end

  # ── Formatting ───────────────────────────────────────────────────────────

  defp format(path, string, opts) do
    if opts.format && !opts.dry_run && !opts.check do
      {func, _} = Mix.Tasks.Format.formatter_for_file(path)
      func.(string)
    else
      string
    end
  rescue
    exception ->
      Mix.shell().error("""
      Exception while formatting:

      #{inspect(exception)}

      #{inspect(string)}
      """)

      reraise exception, __STACKTRACE__
  end

  # ── Validation ───────────────────────────────────────────────────────────

  defp require_name!(opts) do
    if !opts.name && !opts.dry_run && !opts.check && !opts.snapshots_only && !opts.dev do
      raise """
      Name must be provided when generating migrations, unless `--dry-run` or `--check` or `--dev` is also provided.

      Please provide a name. For example:

          mix ash_scylla.generate_migrations <name> ...args
      """
    end

    :ok
  end

  # ── Timestamp ────────────────────────────────────────────────────────────

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    current = "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"

    last = Process.get(:ash_scylla_last_migration_timestamp)

    result =
      if last && current <= last do
        increment_timestamp(last)
      else
        current
      end

    Process.put(:ash_scylla_last_migration_timestamp, result)
    result
  end

  defp increment_timestamp(timestamp) do
    <<y::binary-4, m::binary-2, d::binary-2, hh::binary-2, mm::binary-2, ss::binary-2>> =
      timestamp

    seconds =
      :calendar.datetime_to_gregorian_seconds({
        {String.to_integer(y), String.to_integer(m), String.to_integer(d)},
        {String.to_integer(hh), String.to_integer(mm), String.to_integer(ss)}
      })

    {{y, m, d}, {hh, mm, ss}} = :calendar.gregorian_seconds_to_datetime(seconds + 1)
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: <<?0, ?0 + i>>
  defp pad(i), do: to_string(i)
end
