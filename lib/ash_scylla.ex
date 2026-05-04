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
  AshScylla is a data layer for Ash Framework that uses ScyllaDB (via Exandra).

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

  Configure your repo to use Exandra adapter:

      defmodule MyApp.Repo do
        use Ecto.Repo,
          otp_app: :my_app,
          adapter: Exandra
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
  def version do
    {:ok, version} = :application.get_key(:ash_scylla, :vsn)
    to_string(version)
  end
end
