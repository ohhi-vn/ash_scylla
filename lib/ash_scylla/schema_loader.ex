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

defmodule AshScylla.SchemaLoader do
  @moduledoc """
  Loads and discovers schema migration modules from `priv/<repo>/migrations`.

  ## Discovery

  `discover/0` scans all apps (current + umbrella) for `.ex` files under
  `priv/<repo>/migrations/` and returns sorted file paths.

  ## Loading

  `load/1` requires the file, checks for `change/0`, and calls
  `AshScylla.Schema.flatten/1` to normalize the result to a flat CQL list.

  Supports both flat CQL string lists and struct-based `%AshScylla.Schema{}`
  entries.
  """

  @type loaded :: {:ok, module()} | {:error, term()}

  @doc """
  Discovers all `.ex` files under `priv/<repo>/migrations` for the current project.
  """
  @spec discover() :: [String.t()]
  def discover do
    apps = Mix.Project.apps_paths() || %{}
    migrations_glob = Path.join("priv/repo/migrations", "**/*.ex")

    for {_app, path} <- apps,
        file <- Path.wildcard(Path.join(path, migrations_glob)),
        do:
          file
          |> Enum.sort()
  end

  @doc """
  Loads a schema module from a file path and returns its `change/0` statements.

  Supports both flat CQL string lists and struct-based `%AshScylla.Schema{}`
  entries. Struct-based entries are automatically flattened via
  `AshScylla.Schema.flatten/1`.
  """
  @spec load(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def load(path) when is_binary(path) do
    case Code.require_file(path) do
      [{module, _}] when is_atom(module) ->
        if function_exported?(module, :change, 0) do
          {:ok, module.change() |> AshScylla.Schema.flatten()}
        else
          {:error, :no_change_function}
        end

      [] ->
        {:error, :no_module_loaded}

      other ->
        {:error, other}
    end
  rescue
    error -> {:error, error}
  end
end
