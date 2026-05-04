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
  - `:pool_size` - The number of connections in the pool
  - `:sync_connect` - Timeout for initial connection (in milliseconds)
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Ecto.Repo, Keyword.merge(opts, adapter: Exandra)

      @doc """
      Returns the configured keyspace for this repo.
      """
      def keyspace do
        config = __MODULE__.config()
        Keyword.get(config, :keyspace)
      end

      @doc """
      Creates the keyspace if it doesn't exist.
      """
      def create_keyspace(keyspace_name \\ nil) do
        keyspace = keyspace_name || keyspace()

        query = """
        CREATE KEYSPACE IF NOT EXISTS #{keyspace}
        WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1}
        """

        __MODULE__.query(query, [])
      end

      @doc """
      Drops the keyspace if it exists.
      """
      def drop_keyspace(keyspace_name \\ nil) do
        keyspace = keyspace_name || keyspace()

        query = "DROP KEYSPACE IF EXISTS #{keyspace}"
        __MODULE__.query(query, [])
      end
    end
  end
end
