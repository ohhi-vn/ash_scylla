defmodule AshScylla.MigrationCoverageTest do
  @moduledoc """
  Line-coverage tests for AshScylla.Migration: primary-key fallbacks in
  create_table_cql/2, execute/2 against unreachable nodes, and the atom/binary
  variants of the UDT helpers.
  """

  use ExUnit.Case, async: true

  alias AshScylla.Migration

  defmodule QbmNoPkWithId do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      table("qbm_no_pk_with_id")
    end

    attributes do
      attribute(:id, :string, public?: true, primary_key?: false)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule QbmNoPkNoId do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      table("qbm_no_pk_no_id")
    end

    attributes do
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:read])
    end
  end

  describe "create_table_cql without declared primary keys" do
    test "falls back to a bare :id attribute as the primary key" do
      cql = Migration.create_table_cql(QbmNoPkWithId)

      assert cql =~ ~s/"id" TEXT/
      assert cql =~ ~s/PRIMARY KEY ("id")/
      assert cql =~ ~s/"name" TEXT/
    end

    test "omits the PRIMARY KEY clause when no id attribute exists" do
      cql = Migration.create_table_cql(QbmNoPkNoId)

      refute cql =~ "PRIMARY KEY"
      assert cql =~ ~s/"name" TEXT/

      assert cql == """
             CREATE TABLE IF NOT EXISTS "qbm_no_pk_no_id" (
               "name" TEXT
             )
             """
    end
  end

  describe "execute/2" do
    test "delegates to the Migrator with the configured nodes" do
      assert {:error, {1, %Xandra.ConnectionError{}}} =
               Migration.execute(["SELECT now() FROM system.local"],
                 nodes: ["127.0.0.1:59999"],
                 connect_timeout: 100
               )
    end

    test "defaults to the standard node list when no opts are given" do
      assert {:ok, []} = Migration.execute([])
    end
  end

  describe "create_type variants" do
    test "accepts an atom type name" do
      cql = Migration.create_type(:qbm_address_t, city: :text, zip: :string)

      assert cql =~ "CREATE TYPE IF NOT EXISTS qbm_address_t"
      assert cql =~ "city TEXT"
      assert cql =~ "zip TEXT"
    end

    test "create_type_cql delegates to create_type" do
      cql = Migration.create_type_cql("qbm_point_t", x: :double)

      assert cql =~ "CREATE TYPE IF NOT EXISTS qbm_point_t"
      assert cql =~ "x DOUBLE"
    end
  end

  describe "drop_type_cql/1" do
    test "accepts an atom type name" do
      assert Migration.drop_type_cql(:qbm_old_t) == "DROP TYPE IF EXISTS qbm_old_t"
    end

    test "accepts a binary type name" do
      assert Migration.drop_type_cql("qbm_old_t") == "DROP TYPE IF EXISTS qbm_old_t"
    end
  end

  describe "alter_type_cql/3 with atom type name" do
    test ":add action" do
      assert Migration.alter_type_cql(:qbm_addr_t, :add, country: :text) ==
               "ALTER TYPE qbm_addr_t ADD country TEXT"
    end

    test ":rename action" do
      assert Migration.alter_type_cql(:qbm_addr_t, :rename, new_zip: :zip) ==
               "ALTER TYPE qbm_addr_t RENAME zip TO new_zip"
    end
  end

  describe "type_exists_cql/1 with atom type name" do
    test "sanitizes and interpolates the type name" do
      assert Migration.type_exists_cql(:qbm_addr_t) ==
               "SELECT type_name FROM system_schema.types WHERE type_name = 'qbm_addr_t'"
    end
  end
end
