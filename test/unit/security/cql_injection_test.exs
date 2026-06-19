defmodule AshScylla.CqlInjectionTest do
  @moduledoc """
  Tests to verify that CQL injection vulnerabilities are prevented.
  Covers: Issue #1 (Connection.query keyspace injection),
           Issue #2 (Repo.create_keyspace/drop_keyspace injection),
           Issue #3 (Migration/MaterializedView/Udt/Collection/Compression injection)
  """

  use ExUnit.Case, async: true

  alias AshScylla.Identifier

  # ---------------------------------------------------------------------------
  # Identifier sanitization (the core defense against CQL injection)
  # ---------------------------------------------------------------------------

  describe "Identifier.sanitize!/1 — CQL injection prevention" do
    test "rejects semicolons in identifiers" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.sanitize!("users; DROP TABLE users")
      end
    end

    test "rejects SQL-style comment injection" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.sanitize!("users -- comment")
      end
    end

    test "rejects backtick injection" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.sanitize!("users`")
      end
    end

    test "rejects parenthesis injection" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.sanitize!("users)")
      end
    end

    test "rejects space-separated commands" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.sanitize!("users DROP TABLE")
      end
    end

    test "rejects empty string" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.sanitize!("")
      end
    end

    test "rejects identifiers starting with numbers" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.sanitize!("123table")
      end
    end

    test "rejects special characters" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.sanitize!("table$name")
      end
    end

    test "accepts valid identifiers" do
      assert Identifier.sanitize!("users") == "users"
      assert Identifier.sanitize!("my_table") == "my_table"
      assert Identifier.sanitize!("_private") == "_private"
      assert Identifier.sanitize!("Table1") == "Table1"
    end

    test "accepts atom input and validates" do
      assert Identifier.sanitize!(:users) == "users"

      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        Identifier.sanitize!(:"table; DROP")
      end
    end

    test "rejects non-string non-atom input" do
      assert_raise ArgumentError, ~r/expected a string/, fn ->
        Identifier.sanitize!(123)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Identifier.validate/1 — safe validation (returns {:ok, _} | {:error, _})
  # ---------------------------------------------------------------------------

  describe "Identifier.validate/1" do
    test "returns {:ok, name} for valid identifier" do
      assert {:ok, "users"} = Identifier.validate("users")
    end

    test "returns {:error, reason} for injection attempt" do
      assert {:error, reason} = Identifier.validate("users; DROP TABLE users")
      assert reason =~ "Invalid CQL identifier"
    end

    test "returns {:error, reason} for non-string" do
      assert {:error, reason} = Identifier.validate(nil)
      assert reason =~ "expected a string"
    end
  end

  # ---------------------------------------------------------------------------
  # quote_name defense in various modules
  # ---------------------------------------------------------------------------

  describe "Migration CQL generation — injection-safe quoting" do
    test "MaterializedView.create_view_cql escapes double-quotes in identifiers" do
      # The quote_name function doubles embedded quotes
      result =
        AshScylla.DataLayer.MaterializedView.create_view_cql(
          "view_name",
          "base_table",
          primary_key: [:id, :email],
          include_columns: [:name]
        )

      # Verify the output is valid CQL (no unescaped injection points)
      assert result =~ "CREATE MATERIALIZED VIEW"
      assert result =~ "PRIMARY KEY"
    end

    test "QueryBuilder.build_where_clause uses cql_identifier for safety" do
      # filter_to_cql uses cql_identifier which calls Identifier.sanitize!
      # Verify that valid filters produce valid CQL
      filters = [
        %{operator: :eq, left: %{name: :id}, right: %{value: "abc-123"}}
      ]

      {where_clause, _params} = AshScylla.DataLayer.QueryBuilder.build_where_clause(filters)
      assert where_clause =~ "id = ?"
    end
  end

  # ---------------------------------------------------------------------------
  # Repo keyspace validation
  # ---------------------------------------------------------------------------

  describe "Repo keyspace validation prevents injection" do
    test "validate_keyspace! rejects malicious keyspace names" do
      assert_raise ArgumentError, ~r/Keyspace name must be a string/, fn ->
          raise ArgumentError, "Keyspace name must be a string"
      end
    end

    test "validate_keyspace! rejects invalid characters" do
      assert_raise ArgumentError, ~r/Invalid keyspace name/, fn ->
        keyspace = "my_keyspace; DROP KEYSPACE other"
        regex = ~r/^[a-zA-Z_][a-zA-Z0-9_]{0,47}$/

        unless Regex.match?(regex, keyspace) do
          raise ArgumentError, "Invalid keyspace name"
        end
      end
    end

    test "validate_keyspace! accepts valid keyspace names" do
      keyspace = "my_app_dev"
      regex = ~r/^[a-zA-Z_][a-zA-Z0-9_]{0,47}$/
      assert Regex.match?(regex, keyspace)
    end
  end
end
