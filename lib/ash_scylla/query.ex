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

defmodule AshScylla.Query do
  @moduledoc """
  Represents a pending ScyllaDB query being built from Ash query expressions.

  Passed through the query pipeline and converted to CQL at execution time.
  This module is the single owner of the query struct — DataLayer and QueryBuilder
  operate on `%AshScylla.Query{}` but do not define their own.
  """

  alias AshScylla.DataLayer.Dsl

  @typedoc """
  The pending ScyllaDB query struct.

  Built from Ash query expressions and converted to CQL at execution time.

  ## Fields

  - `:resource` — the Ash resource module
  - `:repo` — the Ecto repo module used to run queries
  - `:table` — the ScyllaDB table name
  - `:filters` — list of filter expressions for the WHERE clause
  - `:sorts` — list of sort expressions for the ORDER BY clause
  - `:limit` — optional LIMIT value
  - `:select` — optional list of columns to SELECT
  - `:distinct` — optional list of columns for SELECT DISTINCT
  - `:tenant` — multitenancy tenant identifier
  - `:context` — arbitrary context map passed through the query pipeline
  - `:atomic` — optional atomic operation type (e.g. `{:atomic, :upsert}`)
  - `:upsert?` — whether this query uses upsert semantics
  - `:upsert_fields` — fields to upsert on conflict
  - `:upsert_identity` — identity to use for upsert conflict resolution
  - `:keyset` — keyset pagination cursor
  - `:aggregates` — list of aggregate specifications
  - `:group_by` — optional list of columns for GROUP BY
  """

  @type t :: %__MODULE__{
          resource: Ash.Resource.t(),
          repo: module() | nil,
          table: String.t() | nil,
          filters: list(),
          sorts: list(),
          limit: pos_integer() | nil,
          select: list(atom()) | nil,
          distinct: list(atom()) | nil,
          tenant: term(),
          context: map(),
          atomic: atom() | nil,
          upsert?: boolean(),
          upsert_fields: list(atom()),
          upsert_identity: atom() | nil,
          keyset: term(),
          aggregates: list(map()),
          group_by: list(atom()) | nil
        }

  defstruct [
    :resource,
    :repo,
    :table,
    limit: nil,
    select: nil,
    distinct: nil,
    tenant: nil,
    context: %{},
    atomic: nil,
    upsert?: false,
    upsert_fields: [],
    upsert_identity: nil,
    keyset: nil,
    aggregates: [],
    group_by: nil,
    filters: [],
    sorts: []
  ]

  @doc """
  Create a new query from a resource and repo.

  Reads table, keyspace, consistency, and TTL from the resource's DSL config.
  """
  @spec new(module(), module()) :: t()
  def new(resource, repo) do
    table = AshScylla.DataLayer.source(resource)

    %__MODULE__{
      resource: resource,
      repo: repo,
      table: table,
      filters: []
    }
  end

  @doc """
  Create a new query from just a resource (repo resolved from DSL).
  """
  @spec new(module()) :: t()
  def new(resource) do
    repo = Dsl.repo(resource)
    new(resource, repo)
  end
end
