defmodule AshScylla.TestDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshScylla.TestResource)
    resource(AshScylla.TestResourceWithIndexes)
  end
end

defmodule AshScylla.TestResource do
  @moduledoc false

  use Ash.Resource,
    domain: AshScylla.TestDomain,
    data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl

  ash_scylla do
    repo(AshScylla.TestRepo)
    table("test_resource")
    keyspace("ash_scylla_test")
    consistency(:one)
    ttl(3600)

    secondary_index(:email)
    secondary_index(:name)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :email, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :age, :integer do
      public?(true)
    end

    attribute :password_hash, :string do
      public?(false)
    end

    attribute :org_id, :uuid do
      public?(true)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:update, action: :update)
    define(:destroy, action: :destroy)
  end
end

defmodule AshScylla.TestResourceWithIndexes do
  @moduledoc false

  use Ash.Resource,
    domain: AshScylla.TestDomain,
    data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl

  ash_scylla do
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

    attribute :name, :string do
      allow_nil?(false)
    end

    attribute :email, :string do
      allow_nil?(false)
    end

    attribute :status, :string do
      default("active")
    end

    attribute(:age, :integer)

    create_timestamp(:created_at)
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end
end

defmodule AshScylla.TestRepo do
  @moduledoc false
  use AshScylla.Repo, otp_app: :ash_scylla

  @doc false
  def setup_keyspace do
    create_keyspace("ash_scylla_test")
    query("USE ash_scylla_test", [])
  end

  @doc false
  def drop_test_keyspace do
    drop_keyspace("ash_scylla_test")
  end

  @doc false
  def create_test_resource_table do
    setup_keyspace()

    query(
      """
      CREATE TABLE IF NOT EXISTS test_resource (
        id UUID PRIMARY KEY,
        name TEXT,
        email TEXT,
        age BIGINT,
        password_hash TEXT,
        org_id UUID,
        created_at TIMESTAMP,
        updated_at TIMESTAMP
      )
      """,
      []
    )

    query("CREATE INDEX IF NOT EXISTS idx_test_resource_email ON test_resource (email)", [])
    query("CREATE INDEX IF NOT EXISTS idx_test_resource_name ON test_resource (name)", [])
  end

  @doc false
  def create_test_users_table do
    setup_keyspace()

    query(
      """
      CREATE TABLE IF NOT EXISTS test_users (
        id UUID PRIMARY KEY,
        name TEXT,
        email TEXT,
        status TEXT,
        age BIGINT,
        created_at TIMESTAMP
      )
      """,
      []
    )

    query("CREATE INDEX IF NOT EXISTS idx_test_users_email ON test_users (email)", [])
    query("CREATE INDEX IF NOT EXISTS idx_test_users_status ON test_users (status)", [])
  end

  @doc false
  def truncate_tables do
    query("TRUNCATE ash_scylla_test.test_resource", [])
    query("TRUNCATE ash_scylla_test.test_users", [])
  end
end
