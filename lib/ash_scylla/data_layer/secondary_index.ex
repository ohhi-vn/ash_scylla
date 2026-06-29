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

defmodule AshScylla.DataLayer.SecondaryIndex do
  @moduledoc """
  Struct representing a secondary index definition on a ScyllaDB table.

  Used by the DSL, migration generator, and filter validator to introspect
  index configurations programmatically.

  ## Fields

  - `:columns` — List of column names (atoms) to index
  - `:name` — Optional custom index name override
  - `:options` — Additional index options
  """

  @typedoc """
  A secondary index definition on a ScyllaDB table.

  Used by the DSL, migration generator, and filter validator to introspect
  index configurations programmatically.
  """

  @type t :: %__MODULE__{
          columns: [atom()],
          name: String.t() | nil,
          options: keyword()
        }

  defstruct columns: [],
            name: nil,
            options: []

  @doc """
  Parses a secondary index DSL input into a `%SecondaryIndex{}` struct.

  Accepts three call signatures:
  - A single atom: `:email`
  - A list of atoms: `[:name, :age]`
  - A tuple with options: `{:email, name: "idx_email"}`

  ## Examples

      iex> AshScylla.DataLayer.SecondaryIndex.parse(:email)
      %AshScylla.DataLayer.SecondaryIndex{columns: [:email], name: nil, options: []}

      iex> AshScylla.DataLayer.SecondaryIndex.parse([:name, :age])
      %AshScylla.DataLayer.SecondaryIndex{columns: [:name, :age], name: nil, options: []}

      iex> AshScylla.DataLayer.SecondaryIndex.parse({:email, name: "idx_email"})
      %AshScylla.DataLayer.SecondaryIndex{columns: [:email], name: "idx_email", options: [name: "idx_email"]}
  """
  @spec parse(atom() | [atom()] | {atom(), keyword()}) :: t()
  def parse(column) when is_atom(column) do
    %__MODULE__{columns: [column], name: nil, options: []}
  end

  def parse(columns) when is_list(columns) do
    %__MODULE__{columns: columns, name: nil, options: []}
  end

  def parse({column, opts}) when is_atom(column) and is_list(opts) do
    %__MODULE__{columns: [column], name: opts[:name], options: opts}
  end

  def parse(invalid) do
    raise "Invalid secondary_index configuration: #{inspect(invalid)}"
  end

  @doc """
  Generates the default index name for a given table and column.

  ## Examples

      iex> AshScylla.DataLayer.SecondaryIndex.default_name("users", :email)
      "idx_users_email"
  """
  @spec default_name(String.t(), atom()) :: String.t()
  def default_name(table, column) do
    "idx_#{table}_#{column}"
  end

  @doc """
  Returns the effective index name — custom name if set, otherwise the default.
  """
  @spec effective_name(t(), String.t(), atom()) :: String.t()
  def effective_name(%__MODULE__{name: name}, table, column) do
    case name do
      nil -> default_name(table, column)
      custom -> "#{custom}_#{column}"
    end
  end
end
