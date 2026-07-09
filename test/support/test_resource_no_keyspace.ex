defmodule AshScylla.TestResourceNoKeyspace do
  @moduledoc "Test resource without a configured keyspace, for fallback code paths."
  use Ash.Resource,
    domain: AshScylla.TestDomain,
    data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl

  scylla do
    repo(AshScylla.TestRepo)
    table("test_resource_no_ks")
    consistency(:one)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:age, :integer, public?: true)
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end
end
