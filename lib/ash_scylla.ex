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

defmodule AshScylla do
  @moduledoc """
  AshScylla is a data layer for Ash Framework that uses ScyllaDB (via Xandra).

  ## Usage

  Configure your Ash resource to use AshScylla.DataLayer:

      defmodule MyApp.MyResource do
        use Ash.Resource,
          data_layer: AshScylla.DataLayer

        attributes do
          uuid_primary_key :id
          attribute :name, :string
          attribute :email, :string
        end
      end

  Configure your repo to use AshScylla:

      defmodule MyApp.Repo do
        use AshScylla.Repo,
          otp_app: :my_app
      end

  Then configure your resource to use the repo:

      # In your resource configuration
      use Ash.Resource,
        data_layer: AshScylla.DataLayer,
        repo: MyApp.Repo

  ## Top-Level Functions

  - `verify/2` — Verify repo connection, keyspace, and resource tables
  - `verify!/2` — Same as `verify/2` but raises on failure
  - `migrate/2` — Run migrations for all resources
  - `create_keyspace/2` — Create the configured keyspace
  - `version/0` — Return the AshScylla version string
  """

  defp build_verify_report(
         repo,
         nodes,
         keyspace,
         release_version,
         keyspace_report,
         resource_reports,
         opts
       ) do
    %{
      repo: repo,
      nodes: nodes,
      keyspace: keyspace,
      connection: %{checked?: check_connection?(opts), release_version: release_version},
      keyspace_report: keyspace_report,
      resources: resource_reports
    }
  end

  @spec ensure_repo(term()) :: {:ok, module()} | {:error, term()}
  defp ensure_repo(repo) when is_atom(repo) do
    if Code.ensure_loaded?(repo) do
      {:ok, repo}
    else
      {:error, {:repo_not_loaded, repo}}
    end
  end

  defp ensure_repo(repo), do: {:error, {:invalid_repo, repo}}

  @spec repo_config(module()) :: {:ok, keyword()} | {:error, term()}
  defp repo_config(repo) do
    if function_exported?(repo, :config, 0) do
      try do
        case repo.config() do
          config when is_list(config) -> {:ok, config}
          other -> {:error, {:invalid_repo_config, repo, other}}
        end
      rescue
        error -> {:error, {:repo_config_failed, repo, Exception.message(error)}}
      end
    else
      {:error, {:repo_missing_config, repo}}
    end
  end

  @spec resolve_nodes(keyword(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  defp resolve_nodes(config, opts) do
    config
    |> Keyword.get(:nodes, ["127.0.0.1:9042"])
    |> then(&Keyword.get(opts, :nodes, &1))
    |> normalize_nodes()
  end

  @spec normalize_nodes(term()) :: {:ok, [String.t()]} | {:error, term()}
  defp normalize_nodes(nodes) when is_list(nodes) do
    if Enum.all?(nodes, &is_binary/1) do
      case nodes do
        [] -> {:error, :no_nodes}
        _ -> {:ok, nodes}
      end
    else
      {:error, {:invalid_nodes, nodes}}
    end
  end

  defp normalize_nodes(nodes) when is_binary(nodes), do: normalize_nodes([nodes])
  defp normalize_nodes(nodes), do: {:error, {:invalid_nodes, nodes}}

  @valid_keyspace_regex ~r/^[a-zA-Z_][a-zA-Z0-9_]{0,47}$/

  @spec resolve_keyspace(keyword(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  defp resolve_keyspace(config, opts) do
    config
    |> Keyword.get(:keyspace)
    |> then(&Keyword.get(opts, :keyspace, &1))
    |> validate_keyspace()
  end

  @spec validate_keyspace(term()) :: {:ok, String.t() | nil} | {:error, term()}
  defp validate_keyspace(nil), do: {:ok, nil}

  defp validate_keyspace(keyspace) when is_binary(keyspace) do
    if Regex.match?(@valid_keyspace_regex, keyspace) do
      {:ok, keyspace}
    else
      {:error, {:invalid_keyspace, keyspace}}
    end
  end

  defp validate_keyspace(keyspace), do: {:error, {:invalid_keyspace, keyspace}}

  @spec resolve_resources(keyword()) :: {:ok, [module()]} | {:error, term()}
  defp resolve_resources(opts) do
    case Keyword.get(opts, :resources, []) do
      resources when is_list(resources) -> {:ok, resources}
      resources -> {:error, {:invalid_resources, resources}}
    end
  end

  @spec validate_resource_keyspaces([module()], String.t() | nil) ::
          {:ok, [module()]} | {:error, term()}
  defp validate_resource_keyspaces(resources, repo_keyspace) do
    Enum.reduce_while(resources, {:ok, []}, fn resource, {:ok, acc} ->
      case resource_keyspace(resource, repo_keyspace) do
        {:ok, _keyspace} -> {:cont, {:ok, [resource | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resources} -> {:ok, Enum.reverse(resources)}
      error -> error
    end
  end

  @spec start_connection(atom(), [String.t()], keyword(), keyword()) ::
          {:ok, pid() | :skipped} | {:error, term()}
  defp start_connection(conn_name, nodes, config, opts) do
    if check_connection?(opts) do
      connect_timeout =
        Keyword.get(opts, :connect_timeout, Keyword.get(config, :connect_timeout, 5_000))

      AshScylla.Connection.start_link(
        name: conn_name,
        nodes: nodes,
        connect_timeout: connect_timeout
      )
    else
      {:ok, :skipped}
    end
  end

  @spec check_connection?(keyword()) :: boolean()
  defp check_connection?(opts), do: Keyword.get(opts, :check_connection?, true)

  @spec verify_connection(atom(), keyword()) :: {:ok, term()} | {:error, term()}
  defp verify_connection(conn_name, opts) do
    if check_connection?(opts) do
      verify_connection_query(conn_name)
    else
      {:ok, :skipped}
    end
  end

  defp verify_connection_query(conn_name) do
    case AshScylla.Connection.query(conn_name, "SELECT release_version FROM system.local", [],
           consistency: :one
         ) do
      {:ok, %Xandra.Page{content: [[version | _] | _]}} -> {:ok, version}
      {:ok, %Xandra.Page{content: []}} -> {:error, :connection_query_returned_no_rows}
      {:error, error} -> {:error, {:connection_failed, error}}
      {:ok, result} -> {:ok, result}
    end
  end

  @spec verify_keyspace(atom(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  defp verify_keyspace(_conn_name, nil, _opts),
    do: {:ok, %{name: nil, checked?: false, exists?: nil}}

  defp verify_keyspace(conn_name, keyspace, opts) do
    if check_connection?(opts) do
      query = """
      SELECT keyspace_name
      FROM system_schema.keyspaces
      WHERE keyspace_name = ?
      """

      case AshScylla.Connection.query(conn_name, query, [keyspace], consistency: :one) do
        {:ok, %Xandra.Page{content: [[^keyspace]]}} ->
          {:ok, %{name: keyspace, checked?: true, exists?: true}}

        {:ok, %Xandra.Page{content: []}} ->
          {:error, {:keyspace_not_found, keyspace}}

        {:error, error} ->
          {:error, {:keyspace_check_failed, keyspace, error}}
      end
    else
      {:ok, %{name: keyspace, checked?: false, exists?: nil}}
    end
  end

  @spec verify_resources(atom(), String.t() | nil, [module()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  defp verify_resources(_conn_name, _repo_keyspace, [], _opts), do: {:ok, []}

  defp verify_resources(conn_name, repo_keyspace, resources, opts) do
    if check_connection?(opts) do
      verify_resources_connected(conn_name, repo_keyspace, resources)
    else
      verify_resources_unchecked(repo_keyspace, resources)
    end
  end

  @spec verify_resources_connected(atom(), String.t() | nil, [module()]) ::
          {:ok, [map()]} | {:error, term()}
  defp verify_resources_connected(conn_name, repo_keyspace, resources) do
    Enum.reduce_while(resources, {:ok, []}, fn resource, {:ok, acc} ->
      case verify_resource(conn_name, repo_keyspace, resource) do
        {:ok, report} -> {:cont, {:ok, [report | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> normalize_resource_reports()
  end

  @spec verify_resources_unchecked(String.t() | nil, [module()]) ::
          {:ok, [map()]} | {:error, term()}
  defp verify_resources_unchecked(repo_keyspace, resources) do
    Enum.reduce_while(resources, {:ok, []}, fn resource, {:ok, acc} ->
      case resource_report_without_connection(resource, repo_keyspace) do
        {:ok, report} -> {:cont, {:ok, [report | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> normalize_resource_reports()
  end

  @spec normalize_resource_reports({:ok, [map()]} | term()) ::
          {:ok, [map()]} | term()
  defp normalize_resource_reports({:ok, reports}), do: {:ok, Enum.reverse(reports)}
  defp normalize_resource_reports(error), do: error

  @spec resource_report_without_connection(module(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  defp resource_report_without_connection(resource, repo_keyspace) do
    with {:ok, keyspace} <- resource_keyspace(resource, repo_keyspace),
         {:ok, table} <- safe_source(resource) do
      {:ok,
       %{resource: resource, keyspace: keyspace, table: table, checked?: false, exists?: nil}}
    end
  end

  @spec verify_resource(atom(), String.t() | nil, module()) :: {:ok, map()} | {:error, term()}
  defp verify_resource(conn_name, repo_keyspace, resource) do
    with {:ok, keyspace} <- resource_keyspace(resource, repo_keyspace),
         {:ok, table} <- safe_source(resource) do
      query = """
      SELECT table_name
      FROM system_schema.tables
      WHERE keyspace_name = ? AND table_name = ?
      """

      case AshScylla.Connection.query(conn_name, query, [keyspace, table], consistency: :one) do
        {:ok, %Xandra.Page{content: [[^table]]}} ->
          {:ok,
           %{resource: resource, keyspace: keyspace, table: table, checked?: true, exists?: true}}

        {:ok, %Xandra.Page{content: []}} ->
          {:error, {resource, {:table_not_found, keyspace, table}}}

        {:error, error} ->
          {:error, {resource, {:table_check_failed, keyspace, table, error}}}
      end
    end
  end

  @spec resource_keyspace(module(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  defp resource_keyspace(resource, repo_keyspace) do
    case AshScylla.DataLayer.Dsl.keyspace(resource) || repo_keyspace do
      nil -> {:error, {:missing_keyspace, resource}}
      keyspace -> validate_keyspace(keyspace)
    end
  end

  @spec safe_source(module()) :: {:ok, String.t()} | {:error, term()}
  defp safe_source(resource) do
    {:ok, AshScylla.DataLayer.source(resource)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc """
  Returns the version of AshScylla.
  """
  @spec version() :: String.t()
  def version do
    {:ok, version} = :application.get_key(:ash_scylla, :vsn)
    to_string(version)
  end

  @doc """
  Verifies that a repo can connect to ScyllaDB.

  By default this checks the configured nodes and keyspace. Pass `resources:` to
  also verify that each resource's table exists in the configured keyspace.

  ## Options

  - `:nodes` - Override the configured nodes
  - `:keyspace` - Override the configured keyspace
  - `:connect_timeout` - Override the connection timeout
  - `:resources` - Resource modules whose tables should be verified
  - `:check_connection?` - Whether to open a temporary connection. Defaults to `true`.

  ## Examples

      AshScylla.verify(MyApp.Repo)

      AshScylla.verify(MyApp.Repo, resources: [MyApp.User])

      AshScylla.verify(MyApp.Repo, check_connection?: false)
  """
  @spec verify(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(repo, opts \\ []) do
    with {:ok, repo} <- ensure_repo(repo),
         {:ok, config} <- repo_config(repo),
         {:ok, nodes} <- resolve_nodes(config, opts),
         {:ok, keyspace} <- resolve_keyspace(config, opts),
         {:ok, resources} <- resolve_resources(opts),
         {:ok, _resources} <- validate_resource_keyspaces(resources, keyspace) do
      conn_name = :"ash_scylla_verify_#{:erlang.unique_integer([:positive])}"

      try do
        with {:ok, _} <- start_connection(conn_name, nodes, config, opts),
             {:ok, release_version} <- verify_connection(conn_name, opts),
             {:ok, keyspace_report} <- verify_keyspace(conn_name, keyspace, opts),
             {:ok, resource_reports} <- verify_resources(conn_name, keyspace, resources, opts) do
          {:ok,
           build_verify_report(
             repo,
             nodes,
             keyspace,
             release_version,
             keyspace_report,
             resource_reports,
             opts
           )}
        else
          {:error, reason} -> {:error, reason}
        end
      after
        AshScylla.Connection.stop(conn_name)
      end
    end
  end

  @doc """
  Verifies a repo, raising if verification fails.
  """
  @spec verify!(module(), keyword()) :: map() | no_return()
  def verify!(repo, opts \\ []) do
    case verify(repo, opts) do
      {:ok, report} -> report
      {:error, reason} -> raise "AshScylla verification failed: #{inspect(reason)}"
    end
  end

  @doc """
  Runs migrations for all AshScylla resources against the given repo.

  This is a convenience function for use in release tasks or scripts.

  ## Options

  - `:resources` - List of specific resource modules to migrate (default: auto-discover)
  - `:dry_run` - If true, only log statements without executing
  - `:create_keyspace` - Create the keyspace before migrating

  ## Examples

      AshScylla.migrate(MyApp.Repo)

      AshScylla.migrate(MyApp.Repo, resources: [MyApp.User])

      AshScylla.migrate(MyApp.Repo, dry_run: true)
  """
  @spec migrate(module(), keyword()) :: :ok | {:error, term()}
  def migrate(repo, opts \\ []) do
    AshScylla.Release.migrate(repo, [repo], opts)
  end

  @doc """
  Creates the keyspace for a repo if it doesn't exist.

  ## Examples

      AshScylla.create_keyspace(MyApp.Repo)

      AshScylla.create_keyspace(MyApp.Repo, strategy: :network_topology, topologies: [{"dc1", 3}, {"dc2", 3}])
  """
  @spec create_keyspace(module(), keyword()) :: :ok | {:error, term()}
  def create_keyspace(repo, opts \\ []) do
    AshScylla.Release.create_keyspace(repo, opts)
  end
end
