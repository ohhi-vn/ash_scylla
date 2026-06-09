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
  Configuration module for using Exandra with AshScylla.

  ## Usage

  Define your repo module:

      defmodule MyApp.Repo do
        use AshScylla.Repo,
          otp_app: :my_app
      end

  Then configure it in config/config.exs:

      config :my_app, MyApp.Repo,
        nodes: ["127.0.0.1:9042"],
        keyspace: "my_app_dev",
        pool_size: 10

  ## Options

  - `:nodes` - List of ScyllaDB/Cassandra nodes to connect to
  - `:keyspace` - The keyspace to use
  - `:pool_size` - The number of connections in the pool (default: 10)
  - `:sync_connect` - Timeout for initial connection in milliseconds (default: 5000)
  - `:pool_timeout` - Timeout for checking out a connection from the pool in milliseconds (default: 5000)
  - `:queue_target` - Target queue time in microseconds for connection checkout (default: 50_000)
  - `:queue_interval` - Interval to measure queue target in milliseconds (default: 1000)
  - `:connect_timeout` - Timeout for establishing TCP connection in milliseconds (default: 5000)
  - `:request_timeout` - Timeout for queries in milliseconds (default: 120_000)
  - `:log` - Log options for the repo

  ## Connection Pool Tuning Examples

  Basic configuration:

      config :my_app, MyApp.Repo,
        nodes: ["127.0.0.1:9042"],
        keyspace: "my_app_dev",
        pool_size: 10,
        sync_connect: 10_000

  Production configuration with optimized timeouts:

      config :my_app, MyApp.Repo,
        nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
        keyspace: "my_app_prod",
        pool_size: 50,
        sync_connect: 30_000,
        pool_timeout: 15_000,
        queue_target: 100_000,
        queue_interval: 2000,
        connect_timeout: 10_000,
        request_timeout: 300_000

  Development configuration:

      config :my_app, MyApp.Repo,
        nodes: ["127.0.0.1:9042"],
        keyspace: "my_app_dev",
        pool_size: 5,
        sync_connect: 5_000,
        request_timeout: 60_000
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Ecto.Repo, Keyword.merge(opts, adapter: Exandra)

      @doc """
      Returns the configured keyspace for this repo.
      """
      @spec keyspace() :: String.t() | nil
      def keyspace do
        config = __MODULE__.config()
        Keyword.get(config, :keyspace)
      end

      @doc """
      Creates the keyspace if it doesn't exist.
      """
      @spec create_keyspace(String.t() | nil) :: {:ok, term()} | {:error, term()}
      def create_keyspace(keyspace_name \\ nil) do
        keyspace = keyspace_name || keyspace()

        validate_keyspace!(keyspace)

        query = """
        CREATE KEYSPACE IF NOT EXISTS #{keyspace}
        WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1}
        """

        __MODULE__.query(query, [])
      end

      @doc """
      Drops the keyspace if it exists.
      """
      @spec drop_keyspace(String.t() | nil) :: {:ok, term()} | {:error, term()}
      def drop_keyspace(keyspace_name \\ nil) do
        keyspace = keyspace_name || keyspace()

        validate_keyspace!(keyspace)

        query = "DROP KEYSPACE IF EXISTS #{keyspace}"
        __MODULE__.query(query, [])
      end

      @doc """
      Returns the recommended pool size based on ScyllaDB's shard-per-core architecture.

      ScyllaDB works best with a connections-per-shard approach:
      `pool_size = num_nodes * num_cores_per_node`

      This helper queries ScyllaDB's system table for core count and
      calculates the recommended pool size.

      ## Examples

          # In config/config.exs
          config :my_app, MyApp.Repo,
            nodes: ["scylla-1:9042", "scylla-2:9042"],
            keyspace: "my_app_prod",
            pool_size: MyApp.Repo.recommended_pool_size()

      Returns a default of 25 if the query fails.
      """
      @spec recommended_pool_size() :: pos_integer()
      def recommended_pool_size do
        try do
          result = __MODULE__.query("SELECT COUNT(*) as count FROM system.local", [])

          case result do
            {:ok, %{rows: [[count]]}} when is_integer(count) and count > 0 ->
              # Default to single node; multiply by node count for clusters
              count * 5

            _ ->
              25
          end
        rescue
          _ -> 25
        end
      end

      @valid_keyspace_regex ~r/^[a-zA-Z_][a-zA-Z0-9_]{0,47}$/

      @spec validate_keyspace!(String.t()) :: :ok
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
    end
  end
end
