defmodule BasicApp.Resources.Post do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: BasicApp.Domain

  scylla do
    table("posts")
    keyspace("basic_app_dev")
    consistency(:quorum)

    # TTL: posts expire after 30 days
    ttl(2_592_000)

    # Secondary index for querying by author
    secondary_index(:author_id)
    secondary_index(:status)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, allow_nil?: false)
    attribute(:content, :string)
    attribute(:status, :string, default: "published")
    attribute(:author_id, :uuid, allow_nil?: false)

    # Denormalized author data (common pattern in ScyllaDB)
    attribute(:author_name, :string)
    attribute(:author_email, :string)

    attribute(:tags, {:array, :string})
    attribute(:view_count, :integer, default: 0)
    attribute(:published_at, :utc_datetime_usec)

    attribute :created_at, :utc_datetime_usec do
      default(expr!(now()))
      allow_nil?(false)
    end
  end

  actions do
    defaults([:create, :read, :update, :destroy])

    create :publish do
      argument(:title, :string, allow_nil?: false)
      argument(:content, :string)
      argument(:author_id, :uuid, allow_nil?: false)
      argument(:author_name, :string)
      argument(:author_email, :string)
      argument(:tags, {:array, :string})

      change(set_argument(:status, "published"))
      change(set_argument(:published_at, expr!(now())))
    end

    update :increment_views do
      change(increment(:view_count))
    end
  end

  code_interface do
    define(:publish)
    define(:by_author, args: [:author_id])
    define(:published, get_by: [:status])
    define(:increment_views)
  end
end
