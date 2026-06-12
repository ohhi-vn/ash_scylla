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
# WITHOUT REQUIRED WARRANTIES OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule AshScylla.Repo do
  @moduledoc """
  Configuration module for AshScylla using direct Xandra connections.

  ## Usage

      defmodule MyApp.Repo do
        use AshScylla.Repo,
          otp_app: :my_app
      end

  Then configure it in config/config.exs:

      config :my_app, MyApp.Repo,
        nodes: ["127.0.0.1:9042"],
        keyspace: "my_app_dev"

  ## Adding to your supervision tree

      children = [
        MyApp.Repo,
        # ...
      ]

  ## Options

  - `:nodes` - List of ScyllaDB/Cassandra nodes to connect to
  - `:keyspace` - The keyspace to use
  - `:pool_size` - The number of connections in the pool (default: 5)
  - `:connect_timeout` - TCP connection timeout in ms (default: 5000)
  - `:request_timeout` - Query timeout in ms (default: 120_000)
  """

  defmacro __using__(opts) do
    otp_app = Keyword.get(opts, :otp_app)

    quote do
      @otp_app unquote(otp_app)
      @behaviour AshScylla.Repo

      @doc false
      @impl AshScylla.Repo
      def child_spec(opts) do
        AshScylla.Connection.child_spec(
          [name: __MODULE__] ++ AshScylla.Repo.config_to_conn_opts(__MODULE__)
        )
      end

      @doc "Returns the configured keyspace."
      @impl AshScylla.Repo
      @spec keyspace() :: String.t() | nil
      def keyspace do
        config = __MODULE__.config()
        Keyword.get(config, :keyspace)
      end

      @doc "Returns the configured nodes."
      @impl AshScylla.Repo
      @spec nodes() :: [String.t()]
      def nodes do
        config = __MODULE__.config()
        Keyword.get(config, :nodes, ["127.0.0.1:9042"])
      end

      @doc "Returns the connection struct."
      @impl AshScylla.Repo
      @spec connection() :: AshScylla.Connection.t() | nil
      def connection do
        AshScylla.Connection.get_conn(__MODULE__)
      end

      @doc "Executes a CQL query."
      @impl AshScylla.Repo
      @spec query(String.t(), list(), keyword()) :: {:ok, term()} | {:error, term()}
      def query(cql, params, opts \\ []) do
        AshScylla.Connection.query(__MODULE__, cql, params, opts)
      end

      @doc "Executes a CQL query, raising on error."
      @impl AshScylla.Repo
      @spec query!(String.t(), list(), keyword()) :: term() | no_return()
      def query!(cql, params, opts \\ []) do
        AshScylla.Connection.query!(__MODULE__, cql, params, opts)
      end

      @doc "Prepares a CQL statement."
      @impl AshScylla.Repo
      @spec prepare(String.t(), keyword()) :: {:ok, Xandra.Prepared.t()} | {:error, term()}
      def prepare(cql, opts \\ []) do
        AshScylla.Connection.prepare(__MODULE__, cql, opts)
      end

      @doc "Prepares a CQL statement, raising on error."
      @impl AshScylla.Repo
      @spec prepare!(String.t(), keyword()) :: Xandra.Prepared.t() | no_return()
      def prepare!(cql, opts \\ []) do
        AshScylla.Connection.prepare!(__MODULE__, cql, opts)
      end

      @doc "Creates the keyspace if it doesn't exist."
      @impl AshScylla.Repo
      @spec create_keyspace(String.t() | nil) :: {:ok, term()} | {:error, term()}
      def create_keyspace(keyspace_name \\ nil) do
        keyspace = keyspace_name || keyspace()
        validate_keyspace!(keyspace)

        # Start a temporary connection without keyspace to create it
        temp_name = :"#{__MODULE__}_temp_#{:erlang.unique_integer([:positive])}"
        nodes = nodes()

        conn_opts = [
          name: temp_name,
          nodes: nodes,
          pool_size: 1
        ]

        with {:ok, _} <- AshScylla.Connection.start_link(conn_opts) do
          query = """
          CREATE KEYSPACE IF NOT EXISTS #{keyspace}
          WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1}
          """

          result = AshScylla.Connection.query(temp_name, query, [], consistency: :quorum)
          AshScylla.Connection.stop(temp_name)
          result
        end
      end

      @doc "Drops the keyspace if it doesn't exist."
      @impl AshScylla.Repo
      @spec drop_keyspace(String.t() | nil) :: {:ok, term()} | {:error, term()}
      def drop_keyspace(keyspace_name \\ nil) do
        keyspace = keyspace_name || keyspace()
        validate_keyspace!(keyspace)

        query = "DROP KEYSPACE IF EXISTS #{keyspace}"
        __MODULE__.query(query, [], consistency: :quorum)
      end

      @valid_keyspace_regex ~r/^[a-zA-Z_][a-zA-Z0-9_]{0,47}$/

      defp validate_keyspace!(keyspace) do
        unless is_binary(keyspace) do
          raise ArgumentError, "Keyspace name must be a string, got: #{inspect(keyspace)}"
        end

        unless Regex.match?(@valid_keyspace_regex, keyspace) do
          raise ArgumentError,
                "Invalid keyspace name: #{inspect(keyspace)}. Keyspace names must match #{@valid_keyspace_regex.source}"
        end

        :ok
      end

      @impl AshScylla.Repo
      @spec config() :: keyword()
      def config do
        case Application.get_env(@otp_app, __MODULE__) do
          nil -> []
          config when is_list(config) -> config
        end
      end

      defoverridable config: 0
    end
  end

  @callback config() :: keyword()
  @callback keyspace() :: String.t() | nil
  @callback nodes() :: [String.t()]
  @callback connection() :: AshScylla.Connection.t() | nil
  @callback query(String.t(), list(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback query!(String.t(), list(), keyword()) :: term() | no_return()
  @callback prepare(String.t(), keyword()) :: {:ok, Xandra.Prepared.t()} | {:error, term()}
  @callback prepare!(String.t(), keyword()) :: Xandra.Prepared.t() | no_return()
  @callback create_keyspace(String.t() | nil) :: {:ok, term()} | {:error, term()}
  @callback drop_keyspace(String.t() | nil) :: {:ok, term()} | {:error, term()}
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @doc "Converts repo config to Xandra connection options."
  @spec config_to_conn_opts(module()) :: keyword()
  def config_to_conn_opts(repo_module) do
    config = repo_module.config()

    [
      nodes: Keyword.get(config, :nodes, ["127.0.0.1:9042"]),
      keyspace: Keyword.get(config, :keyspace),
      pool_size: Keyword.get(config, :pool_size, 5),
      connect_timeout: Keyword.get(config, :connect_timeout, 5_000),
      request_timeout: Keyword.get(config, :request_timeout, 120_000)
    ]
  end
end
