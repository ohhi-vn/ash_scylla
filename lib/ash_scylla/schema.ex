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

defmodule AshScylla.Schema do
  @moduledoc """
  Behaviour for schema migration modules loaded from `priv/migrations`.

  Schema files are optional Elixir modules that return CQL statements from
  `change/0`. They are useful for generated or hand-written schema changes that
  should run before AshScylla's resource-driven migrations.

  ## Example

      defmodule MyApp.Migrations.AddUserTable do
        use AshScylla.Schema

        def change do
          [
            "CREATE TABLE IF NOT EXISTS users (id UUID PRIMARY KEY, name TEXT)"
          ]
        end
      end
  """

  @type cql :: String.t()

  @callback change() :: [cql()]

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour AshScylla.Schema

      @doc false
      def change, do: []

      defoverridable change: 0
    end
  end
end
