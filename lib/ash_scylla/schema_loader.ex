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
  Loads and discovers schema migration modules from `priv/migrations`.
  """

  @type loaded :: {:ok, module()} | {:error, term()}

  @doc """
  Discovers all `.ex` files under `priv/migrations` for the current project.
  """
  @spec discover() :: [String.t()]
  def discover do
    apps = Mix.Project.apps_paths() || %{}

    for {_app, path} <- apps,
        file <- Path.wildcard(Path.join(path, "priv/migrations/**/*.ex")),
        do: file
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
