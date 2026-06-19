defmodule AshScylla.PreparedStatementCacheTest do
  @moduledoc """
  Tests for AshScylla.PreparedStatementCache.
  Covers: Issue #10 (invalidate/1 scans entire ETS table)
  """

  use ExUnit.Case, async: false

  alias AshScylla.PreparedStatementCache

  # Mock repo that simulates prepare/2
  defmodule MockRepo do
    @moduledoc false

    def prepare(cql, opts) do
      keyspace = Keyword.get(opts, :keyspace)
      {:ok, {:prepared_stmt, cql, keyspace}}
    end
  end

  # Mock repo that does NOT support prepare/2
  defmodule NoPrepareRepo do
    @moduledoc false
    # intentionally no prepare/2
  end

  setup do
    # Ensure the global cache GenServer is running.
    case PreparedStatementCache.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Clear the cache before each test for isolation.
    PreparedStatementCache.clear()
    :ok
  end

  describe "start_link/1" do
    test "starts a GenServer" do
      # Already started in setup, so this should fail with already_started.
      assert {:error, {:already_started, _pid}} = PreparedStatementCache.start_link([])
    end

    test "creates an ETS table" do
      tid = PreparedStatementCache.table()
      assert tid != nil
    end
  end

  describe "prepare/3" do
    test "prepares and caches a statement on cache miss" do
      cql = "SELECT * FROM users WHERE id = ?"
      assert {:ok, {:prepared_stmt, ^cql, nil}} = PreparedStatementCache.prepare(MockRepo, cql)
      assert PreparedStatementCache.size() == 1
    end

    test "returns cached statement on cache hit" do
      cql = "SELECT * FROM users WHERE email = ?"

      # First call — cache miss
      assert {:ok, stmt} = PreparedStatementCache.prepare(MockRepo, cql)

      # Second call — should return same cached statement
      assert {:ok, ^stmt} = PreparedStatementCache.prepare(MockRepo, cql)
      assert PreparedStatementCache.size() == 1
    end

    test "caches multiple different statements" do
      cql1 = "SELECT * FROM users WHERE id = ?"
      cql2 = "SELECT * FROM users WHERE email = ?"

      assert {:ok, _} = PreparedStatementCache.prepare(MockRepo, cql1)
      assert {:ok, _} = PreparedStatementCache.prepare(MockRepo, cql2)
      assert PreparedStatementCache.size() == 2
    end

    test "returns error when repo does not support prepare/2" do
      cql = "SELECT * FROM t WHERE id = ?"
      assert {:error, :prepare_not_supported} = PreparedStatementCache.prepare(NoPrepareRepo, cql)
    end

    test "uses phash2 for cache keying — same CQL returns same key" do
      cql = "SELECT * FROM users WHERE id = ?"

      {:ok, stmt1} = PreparedStatementCache.prepare(MockRepo, cql)
      {:ok, stmt2} = PreparedStatementCache.prepare(MockRepo, cql)

      assert stmt1 == stmt2
    end

    test "different keyspaces produce different cache entries" do
      cql = "SELECT * FROM users WHERE id = ?"

      # Prepare with default keyspace
      assert {:ok, stmt1} = PreparedStatementCache.prepare(MockRepo, cql, keyspace: "ks1")
      # Prepare with different keyspace
      assert {:ok, stmt2} = PreparedStatementCache.prepare(MockRepo, cql, keyspace: "ks2")

      # Should be different cache entries
      refute stmt1 == stmt2
      assert PreparedStatementCache.size() == 2
    end
  end

  describe "invalidate/1" do
    test "removes a specific cached statement" do
      cql = "SELECT * FROM users WHERE id = ?"
      assert {:ok, _} = PreparedStatementCache.prepare(MockRepo, cql)
      assert PreparedStatementCache.size() == 1

      assert PreparedStatementCache.invalidate(cql) == :ok
      assert PreparedStatementCache.size() == 0
    end

    test "does not affect other cached statements" do
      cql1 = "SELECT * FROM users WHERE id = ?"
      cql2 = "SELECT * FROM users WHERE email = ?"

      assert {:ok, _} = PreparedStatementCache.prepare(MockRepo, cql1)
      assert {:ok, _} = PreparedStatementCache.prepare(MockRepo, cql2)
      assert PreparedStatementCache.size() == 2

      PreparedStatementCache.invalidate(cql1)
      assert PreparedStatementCache.size() == 1
    end

    test "returns :ok even if statement is not cached" do
      assert PreparedStatementCache.invalidate("SELECT * FROM nonexistent") == :ok
    end

    test "removes all entries matching a CQL string regardless of keyspace" do
      cql = "SELECT * FROM users WHERE id = ?"

      # Prepare with different keyspaces
      assert {:ok, _} = PreparedStatementCache.prepare(MockRepo, cql, keyspace: "ks1")
      assert {:ok, _} = PreparedStatementCache.prepare(MockRepo, cql, keyspace: "ks2")
      assert PreparedStatementCache.size() == 2

      # Invalidate should remove all matching CQL
      assert PreparedStatementCache.invalidate(cql) == :ok
      assert PreparedStatementCache.size() == 0
    end
  end

  describe "clear/0" do
    test "removes all cached statements" do
      assert {:ok, _} = PreparedStatementCache.prepare(MockRepo, "SELECT 1")
      assert {:ok, _} = PreparedStatementCache.prepare(MockRepo, "SELECT 2")
      assert {:ok, _} = PreparedStatementCache.prepare(MockRepo, "SELECT 3")
      assert PreparedStatementCache.size() == 3

      assert PreparedStatementCache.clear() == :ok
      assert PreparedStatementCache.size() == 0
    end

    test "returns :ok on empty cache" do
      assert PreparedStatementCache.clear() == :ok
    end
  end

  describe "size/0" do
    test "returns 0 for empty cache" do
      assert PreparedStatementCache.size() == 0
    end

    test "returns correct count after inserts" do
      assert {:ok, _} = PreparedStatementCache.prepare(MockRepo, "SELECT 1")
      assert PreparedStatementCache.size() == 1

      assert {:ok, _} = PreparedStatementCache.prepare(MockRepo, "SELECT 2")
      assert PreparedStatementCache.size() == 2
    end

    test "returns correct count after invalidation" do
      PreparedStatementCache.prepare(MockRepo, "SELECT 1")
      PreparedStatementCache.prepare(MockRepo, "SELECT 2")
      assert PreparedStatementCache.size() == 2

      PreparedStatementCache.invalidate("SELECT 1")
      assert PreparedStatementCache.size() == 1
    end
  end

  describe "table/0" do
    test "returns the ETS table tid" do
      tid = PreparedStatementCache.table()
      assert tid != nil
    end
  end

  describe "cache performance" do
    test "invalidate is efficient with many cached statements" do
      # Populate cache with many statements
      for i <- 1..100 do
        cql = "SELECT * FROM table_#{i} WHERE id = ?"
        PreparedStatementCache.prepare(MockRepo, cql)
      end

      assert PreparedStatementCache.size() == 100

      # Invalidate one — should only remove matching entries
      PreparedStatementCache.invalidate("SELECT * FROM table_50 WHERE id = ?")
      assert PreparedStatementCache.size() == 99
    end

    test "repeated prepare of same statement does not grow cache" do
      cql = "SELECT * FROM users WHERE id = ?"

      for _ <- 1..50 do
        PreparedStatementCache.prepare(MockRepo, cql)
      end

      assert PreparedStatementCache.size() == 1
    end
  end
end
