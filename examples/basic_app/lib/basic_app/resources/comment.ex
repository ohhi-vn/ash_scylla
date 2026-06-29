defmodule BasicApp.Resources.Comment do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: BasicApp.Domain

  scylla do
    table("comments")
    keyspace("basic_app_dev")
    consistency(:one)

    # Composite secondary index
    secondary_index([:post_id, :status])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:content, :string, allow_nil?: false)
    attribute(:post_id, :uuid, allow_nil?: false)
    attribute(:author_id, :uuid, allow_nil?: false)

    # Denormalized data
    attribute(:author_name, :string)
    attribute(:post_title, :string)

    attribute(:status, :string, default: "approved")

    attribute :created_at, :utc_datetime_usec do
      default(expr!(now()))
      allow_nil?(false)
    end
  end

  actions do
    defaults([:create, :read, :update, :destroy])

    create :add_comment do
      argument(:content, :string, allow_nil?: false)
      argument(:post_id, :uuid, allow_nil?: false)
      argument(:author_id, :uuid, allow_nil?: false)
      argument(:author_name, :string)
      argument(:post_title, :string)

      change(set_argument(:status, "approved"))
    end
  end

  code_interface do
    define(:add_comment)
    define(:by_post, args: [:post_id])
    define(:by_post_and_status, args: [:post_id, :status])
  end
end
