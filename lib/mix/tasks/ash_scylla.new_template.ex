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

defmodule Mix.Tasks.AshScylla.NewTemplate do
  @moduledoc """
  Generates an Ash Resource template backed by AshScylla.

  ## Usage

      mix ash_scylla.new_template AddTableUser name:string, email:string

  The task writes a resource file under `lib/<app>/resources/<resource>.ex`.
  It creates a starter template that you can customize with primary keys,
  actions, repo, and ScyllaDB-specific options.

  ## Examples

      mix ash_scylla.new_template User user_id:uuid, name:string, age:int
      mix ash_scylla.new_template AddTableUser name:string, email:string
  """

  @shortdoc "Generates an AshScylla resource template"

  @requirements ["app.start"]

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    case AshScylla.ResourceGenerator.parse_args(args) do
      {:ok, resource_name, attributes} ->
        AshScylla.ResourceGenerator.write_resource(resource_name, attributes)

      {:error, message} ->
        Mix.raise(message)
    end
  end
end
