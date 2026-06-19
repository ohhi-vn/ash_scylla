defmodule AshScylla.TestResource do
  @moduledoc "Test resource for AshScylla unit tests."
  use Ash.Resource,
    domain: AshScylla.TestDomain,
    data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl

  ash_scylla do
    repo(AshScylla.TestRepo)
    table("test_resource")
    keyspace("ash_scylla_test")
    consistency(:one)
    secondary_index(:name)
    secondary_index(:email)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:email, :string, public?: true)
    attribute(:age, :integer, public?: true)
    attribute(:password_hash, :string, public?: false)
    attribute(:org_id, :uuid, public?: true)
    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end
end
