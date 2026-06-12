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
  """

  @doc """
  Returns the version of AshScylla.
  """
  @spec version() :: String.t()
  def version do
    {:ok, version} = :application.get_key(:ash_scylla, :vsn)
    to_string(version)
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
  """
  @spec create_keyspace(module()) :: :ok | {:error, term()}
  def create_keyspace(repo) do
    AshScylla.Release.create_keyspace(repo)
  end
end
