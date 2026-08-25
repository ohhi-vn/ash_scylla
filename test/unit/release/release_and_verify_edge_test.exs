defmodule AshScylla.ReleaseAndVerifyEdgeTest do
  @moduledoc """
  Covers AshScylla.Release default-argument entrypoints, repo-connection
  startup branches, and the AshScylla.verify/verify!/migrate/create_keyspace
  error paths reachable without a live ScyllaDB (unreachable node
  127.0.0.1:59999 fails fast).
  """

  use ExUnit.Case, async: false

  alias AshScylla.Release

  defmodule FvxReleaseMigrateRepo do
    def config,
      do: [nodes: ["127.0.0.1:59999"], keyspace: "fvx_migrate_ks", connect_timeout: 100]

    def nodes, do: ["127.0.0.1:59999"]
    def keyspace, do: "fvx_migrate_ks"

    # Every schema introspection query reports a missing table so that the
    # migration planner produces full DDL without any network round trip.
    def query(_q, _p, _o), do: {:error, %{message: "unconfigured table fvx_missing"}}

    def create_keyspace(_name, _opts), do: {:ok, %{}}
  end

  defmodule FvxReleaseHeldRepo do
    def config,
      do: [nodes: ["127.0.0.1:59999"], keyspace: "fvx_held_ks", connect_timeout: 100]

    def nodes, do: ["127.0.0.1:59999"]
    def keyspace, do: "fvx_held_ks"
  end

  defmodule FvxVerifyRepo do
    def config,
      do: [nodes: ["127.0.0.1:59999"], keyspace: "fvx_verify_ks", connect_timeout: 100]
  end

  defmodule FvxOkKeyspaceRepo do
    def create_keyspace(_name, _opts), do: {:ok, %{}}
  end

  defmodule FvxFailingKeyspaceRepo do
    def create_keyspace(_name, _opts), do: {:error, :nope}
  end

  describe "Release.migrate/2 (default options)" do
    test "runs migrations with default opts and reports failures from unreachable nodes" do
      result = Release.migrate(FvxReleaseMigrateRepo, [FvxReleaseMigrateRepo])

      assert {:error, summary} = result
      assert is_binary(summary)
      assert summary =~ "migration(s) failed"
    end
  end

  describe "Release.ensure_repo_started/1" do
    test "treats an already-running repo connection as success" do
      {:ok, pid} = Task.start(fn -> Process.sleep(:infinity) end)
      Process.register(pid, FvxReleaseHeldRepo)

      assert :ok =
               Release.migrate(FvxReleaseHeldRepo, [FvxReleaseHeldRepo],
                 create_keyspace: false,
                 resources: [],
                 dry_run: true
               )
    after
      if pid = Process.whereis(FvxReleaseHeldRepo), do: Process.exit(pid, :kill)
    end
  end

  describe "Release.create_keyspace/2" do
    test "default options delegate to the repo and return :ok" do
      assert Release.create_keyspace(FvxOkKeyspaceRepo) == :ok
    end

    test "returns the repo error when creation fails" do
      assert Release.create_keyspace(FvxFailingKeyspaceRepo) == {:error, :nope}
    end
  end

  describe "AshScylla.migrate/2 (default options)" do
    test "delegates to Release.migrate with empty opts" do
      assert {:error, summary} = AshScylla.migrate(FvxReleaseMigrateRepo)
      assert summary =~ "migration(s) failed"
    end
  end

  describe "AshScylla.create_keyspace/2 (default options)" do
    test "returns :ok when repo creation succeeds" do
      assert :ok = AshScylla.create_keyspace(FvxOkKeyspaceRepo)
    end

    test "returns the repo error when creation fails" do
      assert {:error, :nope} = AshScylla.create_keyspace(FvxFailingKeyspaceRepo)
    end
  end

  describe "AshScylla.verify/2 with a real connection attempt" do
    test "fails fast with a connection error against an unreachable node" do
      assert {:error, {:connection_failed, %Xandra.ConnectionError{}}} =
               AshScylla.verify(FvxVerifyRepo)
    end

    test "verify! raises when the connection cannot be established" do
      assert_raise RuntimeError, ~r/AshScylla verification failed/, fn ->
        AshScylla.verify!(FvxVerifyRepo)
      end
    end
  end

  describe "AshScylla.verify/2 resource source errors" do
    test "returns an error when a resource's table cannot be resolved" do
      assert {:error, message} =
               AshScylla.verify(AshScylla.TestRepo,
                 check_connection?: false,
                 resources: [:fvx_not_a_resource]
               )

      assert is_binary(message)
    end
  end
end
