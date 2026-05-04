defmodule AshScylla.TestResource do
  @moduledoc """
  A test resource for demonstrating AshScylla usage.
  """

  use Ash.Resource,
    domain: nil,
    data_layer: AshScylla.DataLayer

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
    attribute :age, :integer
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end
