defmodule AshScylla.MigrationTest do
  use ExUnit.Case, async: true

  alias AshScylla.Migration

  describe "ash_type_to_cql_type/2" do
    test "maps :uuid to UUID" do
      assert Migration.ash_type_to_cql_type(:uuid, []) == "UUID"
    end

    test "maps :string to TEXT" do
      assert Migration.ash_type_to_cql_type(:string, []) == "TEXT"
    end

    test "maps :integer to BIGINT" do
      assert Migration.ash_type_to_cql_type(:integer, []) == "BIGINT"
    end

    test "maps :float to DOUBLE (64-bit, matches Elixir float)" do
      assert Migration.ash_type_to_cql_type(:float, []) == "DOUBLE"
    end

    test "maps :double to DOUBLE" do
      assert Migration.ash_type_to_cql_type(:double, []) == "DOUBLE"
    end

    test "maps :boolean to BOOLEAN" do
      assert Migration.ash_type_to_cql_type(:boolean, []) == "BOOLEAN"
    end

    test "maps :timestamp to TIMESTAMP" do
      assert Migration.ash_type_to_cql_type(:timestamp, []) == "TIMESTAMP"
    end

    test "maps :date to DATE" do
      assert Migration.ash_type_to_cql_type(:date, []) == "DATE"
    end

    test "maps :time to TIME" do
      assert Migration.ash_type_to_cql_type(:time, []) == "TIME"
    end

    test "maps :blob to BLOB" do
      assert Migration.ash_type_to_cql_type(:blob, []) == "BLOB"
    end

    test "maps :decimal to DECIMAL" do
      assert Migration.ash_type_to_cql_type(:decimal, []) == "DECIMAL"
    end

    test "maps :duration to DURATION" do
      assert Migration.ash_type_to_cql_type(:duration, []) == "DURATION"
    end

    test "maps :text to TEXT" do
      assert Migration.ash_type_to_cql_type(:text, []) == "TEXT"
    end

    test "maps :utc_datetime to TIMESTAMP" do
      assert Migration.ash_type_to_cql_type(:utc_datetime, []) == "TIMESTAMP"
    end

    test "maps :naive_datetime to TIMESTAMP" do
      assert Migration.ash_type_to_cql_type(:naive_datetime, []) == "TIMESTAMP"
    end

    test "maps :inet to INET" do
      assert Migration.ash_type_to_cql_type(:inet, []) == "INET"
    end

    test "maps :smallint to SMALLINT" do
      assert Migration.ash_type_to_cql_type(:smallint, []) == "SMALLINT"
    end

    test "maps :tinyint to TINYINT" do
      assert Migration.ash_type_to_cql_type(:tinyint, []) == "TINYINT"
    end

    test "maps :binary to BLOB" do
      assert Migration.ash_type_to_cql_type(:binary, []) == "BLOB"
    end
  end

  describe "ash_type_to_cql_type/2 with complex types" do
    test "maps :map to MAP<TEXT, TEXT> by default" do
      assert Migration.ash_type_to_cql_type(:map, []) == "MAP<TEXT, TEXT>"
    end

    test "maps :map with key_type and value_type" do
      result = Migration.ash_type_to_cql_type(:map, key_type: "TEXT", value_type: "INT")
      assert result == "MAP<TEXT, INT>"
    end

    test "maps :array to LIST<TEXT> by default" do
      assert Migration.ash_type_to_cql_type(:array, []) == "LIST<TEXT>"
    end

    test "maps :array with element_type" do
      result = Migration.ash_type_to_cql_type(:array, element_type: "UUID")
      assert result == "LIST<UUID>"
    end

    test "maps :set to SET<TEXT> by default" do
      assert Migration.ash_type_to_cql_type(:set, []) == "SET<TEXT>"
    end

    test "maps :set with element_type" do
      result = Migration.ash_type_to_cql_type(:set, element_type: "INT")
      assert result == "SET<INT>"
    end

    test "maps {:array, :string} to LIST<TEXT>" do
      assert Migration.ash_type_to_cql_type({:array, :string}, []) == "LIST<TEXT>"
    end

    test "maps {:set, :int} to SET<INT>" do
      assert Migration.ash_type_to_cql_type({:set, :int}, []) == "SET<INT>"
    end

    test "maps {:map, :string, :integer} to MAP<TEXT, BIGINT>" do
      assert Migration.ash_type_to_cql_type({:map, :string, :integer}, []) == "MAP<TEXT, BIGINT>"
    end

    test "maps {:tuple, [:int, :string]} to TUPLE<INT, TEXT>" do
      assert Migration.ash_type_to_cql_type({:tuple, [:int, :string]}, []) == "TUPLE<INT, TEXT>"
    end
  end

  describe "ash_type_to_cql_type/2 with frozen option" do
    test "wraps type in frozen<...>" do
      result = Migration.ash_type_to_cql_type(:array, frozen: true)
      assert result == "frozen<LIST<TEXT>>"
    end

    test "wraps map type in frozen<...>" do
      result = Migration.ash_type_to_cql_type(:map, frozen: true)
      assert result == "frozen<MAP<TEXT, TEXT>>"
    end
  end

  describe "ash_type_to_cql_type/2 with unknown type" do
    test "defaults unknown types to TEXT" do
      assert Migration.ash_type_to_cql_type(:custom_type, []) == "TEXT"
    end
  end

  describe "create_table_cql/1" do
    test "generates simple primary key" do
      cql = Migration.create_table_cql(AshScylla.TestResource)
      assert cql =~ "CREATE TABLE IF NOT EXISTS"
      assert cql =~ "PRIMARY KEY"
      assert cql =~ ~s("id" UUID)
      assert cql =~ ~s("name" TEXT)
    end

    test "generates keyspace-qualified table name when keyspace is configured" do
      cql = Migration.create_table_cql(AshScylla.TestResource)
      assert cql =~ ~s("ash_scylla_test")
    end

    test "generates composite primary key for resource with multiple pk attributes" do
      cql = Migration.create_table_cql(AshScylla.TestResourceCompositePK)
      assert cql =~ ~s/PRIMARY KEY ("id", "group_id")/
      assert cql =~ ~s/"id" UUID/
      assert cql =~ ~s/"group_id" UUID/
      assert cql =~ ~s/"content" TEXT/
    end

    test "composite pk columns appear in column list and pk clause" do
      cql = Migration.create_table_cql(AshScylla.TestResourceCompositePK)
      # Both pk columns should be in the column definitions
      assert cql =~ ~s/"id" UUID/
      assert cql =~ ~s/"group_id" UUID/
      # Composite pk clause
      assert cql =~ ~s/PRIMARY KEY ("id", "group_id")/
    end

    test "does not produce trailing comma in column list" do
      cql = Migration.create_table_cql(AshScylla.TestResourceCompositePK)
      refute cql =~ ",)"
      refute cql =~ ", )"
    end

    test "generates valid CQL with secondary indexes" do
      cql = Migration.create_table_cql(AshScylla.TestResourceWithIndexes)
      assert cql =~ "PRIMARY KEY"
      assert cql =~ ~s("name" TEXT)
      assert cql =~ ~s("email" TEXT)
    end
  end

  describe "quote_name/1" do
    test "quotes simple identifiers" do
      assert Migration.quote_name("users") == ~s("users")
    end

    test "quotes atom identifiers" do
      assert Migration.quote_name(:users) == ~s("users")
    end

    test "escapes embedded double quotes" do
      assert Migration.quote_name("user\"table") == ~s("user""table")
    end
  end

  describe "drop_type/1" do
    test "generates DROP TYPE statement" do
      assert Migration.drop_type("address") == "DROP TYPE IF EXISTS address"
    end
  end

  describe "type_exists_cql/1" do
    test "generates type existence check query" do
      assert Migration.type_exists_cql("address") ==
               "SELECT type_name FROM system_schema.types WHERE type_name = 'address'"
    end
  end

  describe "list_types_cql/0" do
    test "generates types listing query" do
      assert Migration.list_types_cql() ==
               "SELECT type_name, field_names, field_types FROM system_schema.types"
    end
  end
end
