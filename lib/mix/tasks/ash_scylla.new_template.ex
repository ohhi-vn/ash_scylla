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

      mix ash_scylla.new_template User name:string, email:string
      mix ash_scylla.new_template User name:string --domain MyApp.MyDomain
      mix ash_scylla.new_template User name:string --resource MyApp.MyDomain.User

  The task writes a resource file under `lib/<app>/resources/<resource>.ex`.
  It creates a starter template that you can customize with primary keys,
  actions, repo, domain, and ScyllaDB-specific options.

  ## Options

  - `--domain` - Domain module to include in the generated resource.
    The resource name is automatically prefixed with the domain module.
    For example: `--domain MyApp.MyDomain` with name `User` produces
    `MyApp.MyDomain.User`.

  - `--resource` - Fully-qualified resource module name. Overrides the
    positional name argument entirely.
    For example: `--resource MyApp.MyDomain.User`.

  ## Examples

      # Simple resource (no domain)
      mix ash_scylla.new_template User user_id:uuid, name:string, age:int

      # Resource with domain (auto-prefixes name)
      mix ash_scylla.new_template User name:string --domain MyApp.MyDomain

      # Resource with fully-qualified name
      mix ash_scylla.new_template User name:string --resource MyApp.Games.User
  """

  @shortdoc "Generates an AshScylla resource template"

  @requirements ["app.start"]

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, remaining} = parse_cli_opts(args)

    case AshScylla.ResourceGenerator.parse_args(remaining, opts) do
      {:ok, resource_name, attributes, extra_opts} ->
        merged_opts = Keyword.merge(opts, extra_opts)
        AshScylla.ResourceGenerator.write_resource(resource_name, attributes, merged_opts)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp parse_cli_opts(args) do
    {opts, remaining} =
      OptionParser.parse!(args,
        strict: [domain: :string, resource: :string],
        aliases: []
      )

    opts =
      opts
      |> AshScylla.MixHelpers.maybe_atomize(:domain)
      |> AshScylla.MixHelpers.maybe_atomize(:resource)

    {opts, remaining}
  end
end
