defmodule AshScylla.IdentifierQuoteNameTest do
  @moduledoc """
  Tests for AshScylla.Identifier.quote_name/1 and validate_keyspace!/1.
  """

  use ExUnit.Case, async: true

  alias AshScylla.Identifier

  describe "quote_name/1" do
    test "quotes a simple identifier" do
      assert Identifier.quote_name("users") == ~s("users")
    end

    test "quotes an atom" do
      assert Identifier.quote_name(:my_table) == ~s("my_table")
    end

    test "raises for identifier containing double quotes" do
      # Double quotes are not valid CQL identifier characters
      assert_raise ArgumentError, fn ->
        Identifier.quote_name("table\"name")
      end
    end

    test "raises for invalid identifier with semicolon" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.quote_name("users; DROP TABLE users")
      end
    end

    test "raises for empty string" do
      assert_raise ArgumentError, fn ->
        Identifier.quote_name("")
      end
    end

    test "treats nil as atom (Elixir nil is an atom)" do
      # nil is an atom in Elixir, so it's converted to "nil" and quoted
      assert Identifier.quote_name(nil) == ~s("nil")
    end

    test "raises for integer" do
      assert_raise ArgumentError, fn ->
        Identifier.quote_name(42)
      end
    end

    test "raises for identifier starting with number" do
      assert_raise ArgumentError, fn ->
        Identifier.quote_name("123table")
      end
    end
  end

  describe "validate_keyspace!/1" do
    test "accepts valid keyspace name" do
      assert Identifier.validate_keyspace!("my_app") == "my_app"
    end

    test "accepts atom keyspace name" do
      assert Identifier.validate_keyspace!(:my_app) == "my_app"
    end

    test "accepts keyspace with underscores" do
      assert Identifier.validate_keyspace!("my_app_v2") == "my_app_v2"
    end

    test "accepts max length keyspace (48 chars)" do
      name = String.duplicate("a", 48)
      assert Identifier.validate_keyspace!(name) == name
    end

    test "rejects keyspace with semicolon" do
      assert_raise ArgumentError, fn ->
        Identifier.validate_keyspace!("app; DROP KEYSPACE")
      end
    end

    test "rejects keyspace with space" do
      assert_raise ArgumentError, fn ->
        Identifier.validate_keyspace!("my app")
      end
    end

    test "rejects keyspace starting with number" do
      assert_raise ArgumentError, fn ->
        Identifier.validate_keyspace!("123app")
      end
    end

    test "rejects keyspace exceeding 48 chars" do
      assert_raise ArgumentError, fn ->
        Identifier.validate_keyspace!(String.duplicate("a", 49))
      end
    end

    test "rejects non-string non-atom" do
      assert_raise ArgumentError, fn ->
        Identifier.validate_keyspace!(123)
      end
    end
  end

  describe "valid_keyspace_regex/0" do
    test "returns the compiled regex" do
      regex = Identifier.valid_keyspace_regex()
      assert %Regex{} = regex
      assert Regex.match?(regex, "valid_keyspace")
      refute Regex.match?(regex, "invalid keyspace")
    end
  end
end
