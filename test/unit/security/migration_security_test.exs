defmodule AshScylla.MigrationSecurityTest do
  @moduledoc """
  Security tests for migration CQL generation — ensures that:
  - Generated CQL is injection-free
  - Table names, column names, and keyspace names are sanitized
  - UDT field names are validated
  - Index names are safe
  """

  use ExUnit.Case, async: true

  alias AshScylla.Migration
  alias AshScylla.Identifier

  # ---------------------------------------------------------------------------
  # CQL identifier quoting prevents injection
  # ---------------------------------------------------------------------------

  describe "quote_name prevents injection" do
    test "valid identifiers are quoted correctly" do
      assert Identifier.quote_name("users") == "\"users\""
      assert Identifier.quote_name(:users) == "\"users\""
    end

    test "identifiers with embedded double quotes are escaped" do
      # Per CQL spec, embedded " are doubled
      result = Identifier.do_quote_name("my\"table")
      assert result == "\"my\"\"table\""
    end

    test "malicious identifiers are rejected before quoting" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.quote_name("users; DROP TABLE users")
      end
    end

    test "identifiers with spaces are rejected" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.quote_name("my table")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Keyspace name validation
  # ---------------------------------------------------------------------------

  describe "keyspace name validation" do
    test "valid keyspace names are accepted" do
      assert Identifier.validate_keyspace!("my_app") == "my_app"
      assert Identifier.validate_keyspace!("_private") == "_private"
    end

    test "keyspace names with injection are rejected" do
      assert_raise ArgumentError, ~r/Invalid keyspace name/, fn ->
        Identifier.validate_keyspace!("my_ks; DROP KEYSPACE other")
      end
    end

    test "overly long keyspace names are rejected" do
      # 48 chars exceeds the 47-char limit (regex allows 0-47 additional chars)
      long_name = String.duplicate("a", 49)

      assert_raise ArgumentError, ~r/Invalid keyspace name/, fn ->
        Identifier.validate_keyspace!(long_name)
      end
    end

    test "keyspace names starting with numbers are rejected" do
      assert_raise ArgumentError, ~r/Invalid keyspace name/, fn ->
        Identifier.validate_keyspace!("123keyspace")
      end
    end

    test "non-string keyspace names are rejected" do
      assert_raise ArgumentError, ~r/must be a string/, fn ->
        Identifier.validate_keyspace!(123)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Migration CQL generation safety
  # ---------------------------------------------------------------------------

  describe "migration CQL generation safety" do
    test "create_table_cql produces valid CQL without injection points" do
      cql = Migration.create_table_cql(AshScylla.TestResource)

      # Should be valid CQL
      assert cql =~ "CREATE TABLE IF NOT EXISTS"
      assert cql =~ "PRIMARY KEY"
      # Should not contain any injection patterns
      refute cql =~ "; DROP"
      refute cql =~ "--"
      refute cql =~ "ALLOW FILTERING"
    end

    test "create_secondary_indexes_cql produces safe index CQL" do
      cql_list = Migration.create_secondary_indexes_cql(AshScylla.TestResourceWithIndexes)

      for cql <- cql_list do
        assert cql =~ "CREATE INDEX IF NOT EXISTS"
        refute cql =~ "; DROP"
        refute cql =~ "--"
      end
    end

    test "drop_secondary_index_cql produces safe drop CQL" do
      cql = Migration.drop_secondary_index_cql(AshScylla.TestResource, "idx_users_email")
      assert cql == "DROP INDEX IF EXISTS idx_users_email"
      refute cql =~ ";"
    end
  end

  # ---------------------------------------------------------------------------
  # UDT CQL generation safety
  # ---------------------------------------------------------------------------

  describe "UDT CQL generation safety" do
    test "create_type produces valid CQL" do
      cql = Migration.create_type("address", city: :text, street: :text, zip: :text)
      assert cql =~ "CREATE TYPE IF NOT EXISTS"
      assert cql =~ "city"
      assert cql =~ "TEXT"
      refute cql =~ "; DROP"
    end

    test "drop_type produces valid CQL" do
      cql = Migration.drop_type("address")
      assert cql == "DROP TYPE IF EXISTS address"
    end

    test "alter_type_cql add produces valid CQL" do
      cql = Migration.alter_type_cql("address", :add, country: :text)
      assert cql =~ "ALTER TYPE"
      assert cql =~ "ADD"
      refute cql =~ "; DROP"
    end

    test "alter_type_cql rename produces valid CQL" do
      cql = Migration.alter_type_cql("address", :rename, new_zip: :zip_code)
      assert cql =~ "ALTER TYPE"
      assert cql =~ "RENAME"
    end
  end

  # ---------------------------------------------------------------------------
  # Type conversion safety
  # ---------------------------------------------------------------------------

  describe "ash_type_to_cql_type safety" do
    test "known types produce valid CQL type strings" do
      assert Migration.ash_type_to_cql_type(:uuid, []) == "UUID"
      assert Migration.ash_type_to_cql_type(:string, []) == "TEXT"
      assert Migration.ash_type_to_cql_type(:integer, []) == "BIGINT"
      assert Migration.ash_type_to_cql_type(:boolean, []) == "BOOLEAN"
    end

    test "collection types produce valid CQL" do
      result = Migration.ash_type_to_cql_type(:map, key_type: "TEXT", value_type: "INT")
      assert result =~ "MAP"
      assert result =~ "TEXT"
      assert result =~ "INT"
    end
  end
end
