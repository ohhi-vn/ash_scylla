defmodule AshScylla.SecondTestDomain.Resource do
  @moduledoc """
  Resource in the second test domain.

  Shares `AshScylla.TestRepo` with `AshScylla.TestResource` (domain A) but
  declares its own resource-level keyspace, so queries from the two domains
  resolve to different keyspaces while still using the same repo connection.
  """
  use Ash.Resource,
    domain: AshScylla.SecondTestDomain,
    data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl

  scylla do
    repo(AshScylla.TestRepo)
    table("second_domain_resources")
    keyspace("ash_scylla_second_test")
    consistency(:one)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:org_id, :uuid, public?: true)
    create_timestamp(:created_at)
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end
end
