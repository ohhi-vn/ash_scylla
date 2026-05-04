defmodule AshScylla.TestResource do
  @moduledoc """
  A test resource for demonstrating AshScylla usage with secondary indexes.
  """

  use Ash.Resource,
    domain: nil,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    table "test_users"
    keyspace "ash_scylla_test"
    consistency :quorum
    ttl 3600

    # Define secondary indexes for non-primary key columns
    secondary_index :email
    secondary_index [:name, :age]
    secondary_index :status, name: "idx_user_status"
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
    attribute :status, :string
    attribute :age, :integer
    attribute :created_at, :utc_datetime
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end
