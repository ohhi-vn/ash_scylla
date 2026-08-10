defmodule AshScylla.SecondTestDomain.RepoBackedResource do
  @moduledoc """
  Resource in the second test domain whose keyspace is resolved from its repo
  (`AshScylla.SecondTestRepo`) rather than from resource-level DSL.

  Exercises repo-level keyspace resolution for resources living outside the
  primary test domain.
  """
  use Ash.Resource,
    domain: AshScylla.SecondTestDomain,
    data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl

  scylla do
    repo(AshScylla.SecondTestRepo)
    table("repo_backed_resources")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end
end
