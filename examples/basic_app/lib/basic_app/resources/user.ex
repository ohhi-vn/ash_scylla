defmodule BasicApp.Resources.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: BasicApp.Domain

  ash_scylla do
    table("users")
    keyspace("basic_app_dev")
    consistency(:quorum)

    # Secondary indexes for querying by non-primary key fields
    secondary_index(:email)
    secondary_index(:status)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string)
    attribute(:email, :string, allow_nil?: false)
    attribute(:status, :string, default: "active")
    attribute(:age, :integer)
    attribute(:tags, {:array, :string})
    attribute(:metadata, :map)

    attribute :created_at, :utc_datetime_usec do
      default(expr!(now()))
      allow_nil?(false)
    end
  end

  actions do
    defaults([:create, :read, :update, :destroy])

    create :register do
      argument(:name, :string, allow_nil?: false)
      argument(:email, :string, allow_nil?: false)
      argument(:age, :integer)

      change(set_argument(:status, "active"))
    end
  end

  code_interface do
    define(:register)
    define(:by_email, args: [:email])
    define(:active_users, get_by: [:status])
  end
end
