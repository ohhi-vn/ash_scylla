defmodule AshScylla.DataLayer.BatchTest do
  @moduledoc """
  Comprehensive tests for AshScylla.DataLayer.Batch module.
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer.Batch

  # Define a mock repo inline — async: false avoids module redefinition conflicts
  defmodule MockRepo do
    @moduledoc false
    def query(_q, _p, _opts \\ []), do: {:ok, %{}}
  end

  # ============================================================================
  # batch_insert — validation
  # ============================================================================

  describe "batch_insert/2 — invalid statements" do
    test "raises ArgumentError for statement with non-list params" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_insert(MockRepo, [{"query", "not_a_list"}])
      end
    end

    test "raises ArgumentError for 1-tuple statement" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        # Build a list containing a 1-tuple at runtime to avoid compiler warning
        statements = [List.to_tuple(["query"])]
        Batch.batch_insert(MockRepo, statements)
      end
    end

    test "raises ArgumentError for non-string query" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_insert(MockRepo, [{:not_string, []}])
      end
    end

    test "raises ArgumentError for nil statement" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_insert(MockRepo, [nil])
      end
    end

    test "raises ArgumentError for integer statement" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_insert(MockRepo, [123])
      end
    end
  end

  # ============================================================================
  # batch_insert — valid statements
  # ============================================================================

  describe "batch_insert/2 — valid statements" do
    test "single valid statement returns ok" do
      statements = [{"INSERT INTO t (id) VALUES (?)", [1]}]
      assert {:ok, _} = Batch.batch_insert(MockRepo, statements)
    end

    test "multiple valid statements return ok" do
      statements = [
        {"INSERT INTO t (id, name) VALUES (?, ?)", [1, "Alice"]},
        {"INSERT INTO t (id, name) VALUES (?, ?)", [2, "Bob"]}
      ]

      assert {:ok, _} = Batch.batch_insert(MockRepo, statements)
    end

    test "empty statements return ok with empty list" do
      assert {:ok, []} = Batch.batch_insert(MockRepo, [])
    end
  end

  # ============================================================================
  # batch_update
  # ============================================================================

  describe "batch_update/2" do
    test "valid statements return ok" do
      statements = [
        {"UPDATE t SET name = ? WHERE id = ?", ["Alice", 1]},
        {"UPDATE t SET name = ? WHERE id = ?", ["Bob", 2]}
      ]

      assert {:ok, _} = Batch.batch_update(MockRepo, statements)
    end

    test "empty statements return ok with empty list" do
      assert {:ok, []} = Batch.batch_update(MockRepo, [])
    end

    test "raises ArgumentError for invalid statement" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_update(MockRepo, [{"UPDATE t SET x = ?", "bad"}])
      end
    end
  end

  # ============================================================================
  # batch_delete
  # ============================================================================

  describe "batch_delete/2" do
    test "valid statements return ok" do
      statements = [
        {"DELETE FROM t WHERE id = ?", [1]},
        {"DELETE FROM t WHERE id = ?", [2]}
      ]

      assert {:ok, _} = Batch.batch_delete(MockRepo, statements)
    end

    test "empty statements return ok with empty list" do
      assert {:ok, []} = Batch.batch_delete(MockRepo, [])
    end

    test "raises ArgumentError for invalid statement" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_delete(MockRepo, [nil])
      end
    end
  end
end

# ============================================================================
# MaterializedView Tests
# ============================================================================

defmodule AshScylla.DataLayer.MaterializedViewTest do
  @moduledoc """
  Comprehensive tests for AshScylla.DataLayer.MaterializedView module.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.MaterializedView

  # ============================================================================
  # create_view_cql/3
  # ============================================================================

  describe "create_view_cql/3" do
    test "basic view with partition key and clustering key" do
      cql =
        MaterializedView.create_view_cql(:users_by_email, "users",
          primary_key: [:email, :id],
          include_columns: [:name, :age]
        )

      assert String.contains?(cql, "CREATE MATERIALIZED VIEW IF NOT EXISTS users_by_email")
      assert String.contains?(cql, "AS SELECT \"email\", \"id\", \"name\", \"age\"")
      assert String.contains?(cql, "FROM \"users\"")
      assert String.contains?(cql, "WHERE \"email\" IS NOT NULL AND \"id\" IS NOT NULL")
      assert String.contains?(cql, "PRIMARY KEY ((\"email\"), \"id\")")
    end

    test "single partition key with no clustering keys" do
      cql =
        MaterializedView.create_view_cql(:users_by_id, "users",
          primary_key: [:id],
          include_columns: [:name]
        )

      assert String.contains?(cql, "PRIMARY KEY (\"id\")")
    end

    test "with clustering order" do
      cql =
        MaterializedView.create_view_cql(:users_by_email, "users",
          primary_key: [:email, :id],
          include_columns: [:name],
          clustering_order: [id: :desc]
        )

      assert String.contains?(cql, "WITH CLUSTERING ORDER BY (\"id\" desc)")
    end

    test "with custom WHERE clause" do
      cql =
        MaterializedView.create_view_cql(:users_by_email, "users",
          primary_key: [:email, :id],
          include_columns: [:name],
          where_clause: "email IS NOT NULL AND id IS NOT NULL AND status = 'active'"
        )

      assert String.contains?(cql, "status = 'active'")
    end

    test "empty include_columns selects only primary key columns" do
      cql =
        MaterializedView.create_view_cql(:users_by_id, "users", primary_key: [:id])

      assert String.contains?(cql, "AS SELECT \"id\"")
    end

    test "multiple clustering keys" do
      cql =
        MaterializedView.create_view_cql(:view, "t",
          primary_key: [:a, :b, :c],
          include_columns: [:d]
        )

      assert String.contains?(cql, "PRIMARY KEY ((\"a\"), \"b\", \"c\")")
    end

    test "deduplication when include_columns overlap with primary_key" do
      cql =
        MaterializedView.create_view_cql(:view, "t",
          primary_key: [:id],
          include_columns: [:id, :name]
        )

      # id should appear only once in SELECT
      assert String.contains?(cql, "AS SELECT \"id\", \"name\"")
      refute String.contains?(cql, "\"id\", \"id\"")
    end
  end

  # ============================================================================
  # drop_view_cql/1
  # ============================================================================

  describe "drop_view_cql/1" do
    test "generates correct DROP statement" do
      cql = MaterializedView.drop_view_cql(:users_by_email)
      assert cql == "DROP MATERIALIZED VIEW IF EXISTS users_by_email"
    end
  end

  # ============================================================================
  # validate_view_config/1
  # ============================================================================

  describe "validate_view_config/1" do
    test "valid config returns :ok" do
      assert :ok =
               MaterializedView.validate_view_config(
                 primary_key: [:email, :id],
                 include_columns: [:name]
               )
    end

    test "missing primary_key returns error" do
      assert {:error, msg} = MaterializedView.validate_view_config(include_columns: [:name])
      assert String.contains?(msg, "primary_key")
    end

    test "empty primary_key returns error" do
      assert {:error, msg} = MaterializedView.validate_view_config(primary_key: [])
      assert String.contains?(msg, "primary_key")
    end

    test "duplicate columns returns error" do
      assert {:error, msg} =
               MaterializedView.validate_view_config(
                 primary_key: [:id],
                 include_columns: [:id, :name]
               )

      assert String.contains?(msg, "duplicate")
    end

    test "valid config without include_columns returns :ok" do
      assert :ok = MaterializedView.validate_view_config(primary_key: [:id])
    end
  end
end
