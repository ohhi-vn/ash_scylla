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

    # Clear the cache before each test for isolation. Tolerate a not-yet/
    # no-longer-alive cache process so a single test can't cascade failures.
    if Process.whereis(PreparedStatementCache) do
      try do
        PreparedStatementCache.clear()
      catch
        :exit, _ -> :ok
      end
    end

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

    test "defaults to a LOCAL registration (per-node), not global" do
      # The default instance started in setup must be registered locally...
      assert is_pid(Process.whereis(PreparedStatementCache))
      # ...and must NOT be registered globally, so it does not collide across
      # clustered nodes.
      assert :global.whereis_name(PreparedStatementCache) == :undefined
    end

    test "name: :undefined also registers locally" do
      # Stop the default instance so we can start a fresh one under the same
      # local name (`:undefined` resolves to the default local name).
      if default = Process.whereis(PreparedStatementCache) do
        GenServer.stop(default)
      end

      {:ok, pid} = PreparedStatementCache.start_link(name: :undefined)
      assert Process.whereis(PreparedStatementCache) == pid
      assert :global.whereis_name(PreparedStatementCache) == :undefined
      GenServer.stop(pid)

      # Restore the default instance for the remaining tests.
      PreparedStatementCache.start_link([])
    end

    test "explicit local name registers locally under that name" do
      {:ok, pid} = PreparedStatementCache.start_link(name: :psc_local_test)
      assert Process.whereis(:psc_local_test) == pid
      assert :global.whereis_name(:psc_local_test) == :undefined
      GenServer.stop(pid)
    end

    test "explicit {:global, name} registers globally when requested" do
      {:ok, pid} = PreparedStatementCache.start_link(name: {:global, :psc_global_test})
      assert :global.whereis_name(:psc_global_test) == pid
      GenServer.stop(pid)
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

  describe "eviction (Bug 7 fix)" do
    test "evict_oldest actually deletes entries instead of no-op'ing on `true`" do
      # Populate well beyond the max cache size so cleanup must evict.
      for i <- 1..(PreparedStatementCache.max_cache_size() + 50) do
        cql = "SELECT * FROM evict_table_#{i} WHERE id = ?"
        PreparedStatementCache.prepare(MockRepo, cql)
      end

      # The cache must not grow unbounded past @max_cache_size.
      assert PreparedStatementCache.size() <= PreparedStatementCache.max_cache_size()
    end

    test "evict_oldest removes real keys (regression for `:ets.delete(tid, true)`)" do
      # The ETS table is `protected` (only the GenServer owner may write/delete),
      # so we exercise eviction through the public prepare path: once the cache
      # exceeds @max_cache_size, the cleanup must evict real entries rather than
      # no-op'ing on the atom `true`.
      max = PreparedStatementCache.max_cache_size()

      for i <- 1..(max + 25) do
        PreparedStatementCache.prepare(MockRepo, "SELECT * FROM evict_k_#{i} WHERE id = ?")
      end

      # Cache must not grow unbounded past the configured maximum.
      assert PreparedStatementCache.size() <= max

      # And it must have actually evicted something (not stayed at max+25).
      refute PreparedStatementCache.size() == max + 25
    end
  end

  describe "max_cache_size/0" do
    test "exposes the configured limit" do
      assert PreparedStatementCache.max_cache_size() == 10_000
    end
  end
end
