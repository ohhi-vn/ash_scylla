defmodule AshScylla.DataLayer.SchemaUtilsTest do
  @moduledoc """
  Tests for AshScylla.DataLayer.SchemaUtils — shared schema utilities.
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer.SchemaUtils
  alias AshScylla.Identifier

  describe "get_table_name/1" do
    test "returns DSL table name when configured" do
      # TestResourceWithIndexes has table "test_users" configured in DSL
      result = SchemaUtils.get_table_name(AshScylla.TestResourceWithIndexes)
      assert is_binary(result)
      assert result == "test_users"
    end

    test "derives table name from module when no DSL config" do
      # TestResource has no explicit table config
      result = SchemaUtils.get_table_name(AshScylla.TestResource)
      assert is_binary(result)
    end
  end

  describe "quote_name/1" do
    test "quotes a valid identifier" do
      assert SchemaUtils.quote_name("users") == ~s("users")
    end

    test "quotes an atom identifier" do
      assert SchemaUtils.quote_name(:users) == ~s("users")
    end

    test "raises for identifier containing double quotes" do
      # Double quotes are not valid in CQL identifiers
      assert_raise ArgumentError, fn ->
        SchemaUtils.quote_name("my\"table")
      end
    end

    test "raises for invalid identifier" do
      assert_raise ArgumentError, fn ->
        SchemaUtils.quote_name("users; DROP TABLE")
      end
    end

    test "raises for empty string" do
      assert_raise ArgumentError, fn ->
        SchemaUtils.quote_name("")
      end
    end

    test "raises for non-string non-atom" do
      assert_raise ArgumentError, fn ->
        SchemaUtils.quote_name(123)
      end
    end
  end

  describe "quote_name_unchecked/1" do
    test "quotes without validation" do
      assert SchemaUtils.quote_name_unchecked("users") == ~s("users")
    end

    test "escapes double quotes" do
      assert SchemaUtils.quote_name_unchecked("a\"b") == ~s("a""b")
    end
  end

  describe "unindexable_columns/1" do
    test "returns empty list for resource with composite PK" do
      # TestResource has only :id as PK (sole partition key)
      result = SchemaUtils.unindexable_columns(AshScylla.TestResource)
      assert is_list(result)
    end

    test "returns empty list for plain module" do
      result = SchemaUtils.unindexable_columns(SomePlainModule)
      assert result == []
    end
  end

  describe "sanitize_type_name/1" do
    test "returns valid type name" do
      assert SchemaUtils.sanitize_type_name("MyType") == "MyType"
    end

    test "accepts atom" do
      assert SchemaUtils.sanitize_type_name(:my_type) == "my_type"
    end

    test "raises for invalid characters" do
      assert_raise ArgumentError, fn ->
        SchemaUtils.sanitize_type_name("type; DROP")
      end
    end
  end
end
