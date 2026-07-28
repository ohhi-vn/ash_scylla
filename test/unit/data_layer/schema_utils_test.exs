defmodule AshScylla.DataLayer.SchemaUtilsTest do
  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.SchemaUtils

  describe "get_table_name/1" do
    test "returns explicitly configured table name" do
      assert SchemaUtils.get_table_name(AshScylla.TestResource) == "test_resource"
    end

    test "returns table name for composite PK resource" do
      assert SchemaUtils.get_table_name(AshScylla.TestResourceCompositePK) == "test_composite_pk"
    end

    test "derives table name from module when no explicit table is set" do
      result = SchemaUtils.get_table_name(AshScylla.TestResourceNoTable)
      assert is_binary(result)
      refute result == ""
    end
  end

  describe "quote_name/1" do
    test "quotes atom name" do
      assert SchemaUtils.quote_name(:my_table) == ~s("my_table")
    end

    test "quotes string name" do
      assert SchemaUtils.quote_name("my_table") == ~s("my_table")
    end

    test "raises on identifier with double quotes" do
      assert_raise ArgumentError, fn ->
        SchemaUtils.quote_name(~s(my"table))
      end
    end

    test "raises on invalid identifier" do
      assert_raise ArgumentError, fn ->
        SchemaUtils.quote_name("123invalid")
      end
    end

    test "raises on non-string-or-atom input" do
      assert_raise ArgumentError, fn ->
        SchemaUtils.quote_name(42)
      end
    end
  end

  describe "quote_name_unchecked/1" do
    test "quotes plain name" do
      assert SchemaUtils.quote_name_unchecked("my_table") == ~s("my_table")
    end

    test "quotes name with special characters" do
      assert SchemaUtils.quote_name_unchecked("my table") == ~s("my table")
    end

    test "escapes embedded double quotes" do
      assert SchemaUtils.quote_name_unchecked(~s(my"table)) == ~s("my""table")
    end

    test "handles empty string" do
      assert SchemaUtils.quote_name_unchecked("") == ~s("")
    end
  end

  describe "unindexable_columns/1" do
    test "returns single partition key column" do
      assert SchemaUtils.unindexable_columns(AshScylla.TestResource) == [:id]
    end

    test "returns empty list for composite partition key" do
      assert SchemaUtils.unindexable_columns(AshScylla.TestResourceCompositePK) == []
    end

    test "returns empty list for non-Ash module" do
      assert SchemaUtils.unindexable_columns(SomeMadeUpModule) == []
    end
  end

  describe "sanitize_type_name/1" do
    test "sanitizes atom type name" do
      assert SchemaUtils.sanitize_type_name(:my_type) == "my_type"
    end

    test "sanitizes string type name" do
      assert SchemaUtils.sanitize_type_name("my_type") == "my_type"
    end

    test "sanitizes type name with uppercase" do
      assert SchemaUtils.sanitize_type_name("MyType") == "MyType"
    end

    test "raises on invalid type name" do
      assert_raise ArgumentError, fn ->
        SchemaUtils.sanitize_type_name("123invalid")
      end
    end
  end
end
