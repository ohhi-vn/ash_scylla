defmodule AshScylla.MaterializedViewTest do
  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.MaterializedView

  describe "create_view_cql/3" do
    test "creates materialized view with simple primary key" do
      cql = MaterializedView.create_view_cql(:users_by_email, "users", primary_key: [:email])

      assert cql =~ ~s(CREATE MATERIALIZED VIEW IF NOT EXISTS "users_by_email")
      assert cql =~ ~s(AS SELECT "email")
      assert cql =~ ~s(FROM "users")
      assert cql =~ ~s(WHERE "email" IS NOT NULL)
      assert cql =~ "PRIMARY KEY (\"email\")"
    end

    test "creates materialized view with composite primary key" do
      cql =
        MaterializedView.create_view_cql(:users_by_email_id, "users", primary_key: [:email, :id])

      assert cql =~ ~s(CREATE MATERIALIZED VIEW IF NOT EXISTS "users_by_email_id")
      assert cql =~ "PRIMARY KEY ((\"email\"), \"id\")"
    end

    test "creates materialized view with include columns" do
      cql =
        MaterializedView.create_view_cql(:users_by_email, "users",
          primary_key: [:email],
          include_columns: [:name, :age]
        )

      assert cql =~ ~s(SELECT "email", "name", "age")
    end

    test "creates materialized view with custom where clause" do
      cql =
        MaterializedView.create_view_cql(:active_users, "users",
          primary_key: [:id],
          where_clause: "status = 'active'"
        )

      assert cql =~ "status = 'active'"
    end

    test "creates materialized view with clustering order" do
      cql =
        MaterializedView.create_view_cql(:users_by_email, "users",
          primary_key: [:email, :id],
          clustering_order: [id: :asc]
        )

      assert cql =~ "CLUSTERING ORDER BY (\"id\" asc)"
    end
  end

  describe "drop_view_cql/1" do
    test "generates DROP MATERIALIZED VIEW statement" do
      cql = MaterializedView.drop_view_cql(:users_by_email)
      assert cql == "DROP MATERIALIZED VIEW IF EXISTS users_by_email"
    end
  end

  describe "validate_view_config/1" do
    test "accepts valid config with primary_key" do
      assert :ok ==
               MaterializedView.validate_view_config(primary_key: [:email])
    end

    test "rejects config without primary_key" do
      assert {:error, "primary_key is required for materialized view"} =
               MaterializedView.validate_view_config([])
    end

    test "rejects config with empty primary_key" do
      assert {:error, "primary_key cannot be empty"} =
               MaterializedView.validate_view_config(primary_key: [])
    end

    test "rejects config with duplicate columns" do
      assert {:error, "duplicate columns in materialized view definition"} =
               MaterializedView.validate_view_config(
                 primary_key: [:email],
                 include_columns: [:email]
               )
    end

    test "accepts config with unique include_columns" do
      assert :ok ==
               MaterializedView.validate_view_config(
                 primary_key: [:email],
                 include_columns: [:name, :age]
               )
    end
  end
end
