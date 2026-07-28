defmodule AshScylla.TestResourceNoTable do
  @moduledoc "Test resource without an explicit table name, for fallback code paths."
  use Ash.Resource,
    domain: AshScylla.TestDomain,
    data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl

  scylla do
    repo(AshScylla.TestRepo)
    keyspace("ash_scylla_test")
    consistency(:one)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end
end
