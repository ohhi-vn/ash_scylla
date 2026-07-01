defmodule AshScylla.TestResourceCompositePK do
  @moduledoc "Test resource with composite primary key for edge case tests."
  use Ash.Resource,
    domain: AshScylla.TestDomain,
    data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


  scylla do
    repo(AshScylla.TestRepo)
    table("test_composite_pk")
    keyspace("ash_scylla_test")
    consistency(:one)
    secondary_index(:group_id)
  end

  attributes do
    attribute(:id, :uuid, public?: true, primary_key?: true, allow_nil?: false)
    attribute(:group_id, :uuid, public?: true, primary_key?: true, allow_nil?: false)
    attribute(:group_type, :string, public?: true)
    attribute(:from_user_id, :uuid, public?: true)
    attribute(:content, :string, public?: true)
    attribute(:order, :integer, public?: true)
    attribute(:deleted, :boolean, public?: true)
    create_timestamp(:inserted_at)
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
