defmodule AshScylla.TestResourceWithIndexes do
  @moduledoc "Test resource with multiple secondary indexes for AshScylla unit tests."
  use Ash.Resource,
    domain: AshScylla.TestDomain,
    data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


  scylla do
    repo(AshScylla.TestRepo)
    table("test_users")
    keyspace("ash_scylla_test")
    consistency(:quorum)
    ttl(3600)
    secondary_index(:email)
    secondary_index([:name, :age])
    secondary_index(:status, name: "idx_user_status")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:email, :string, public?: true)
    attribute(:status, :string, public?: true)
    attribute(:age, :integer, public?: true)
    create_timestamp(:created_at)
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end
end
