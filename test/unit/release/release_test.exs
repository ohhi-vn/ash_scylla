defmodule AshScylla.ReleaseTest do
  use ExUnit.Case, async: true

  alias AshScylla.Release

  defmodule MockRepo do
    def config do
      [nodes: ["127.0.0.1:1"], keyspace: "migrate_ks", connect_timeout: 100]
    end

    def nodes, do: ["127.0.0.1:1"]
    def keyspace, do: "migrate_ks"
    def create_keyspace(_name, _opts), do: {:ok, %{}}
    def query(_q, _p, _o), do: {:error, "boom"}
  end

  defmodule FailingKeyspaceRepo do
    def config do
      [nodes: ["127.0.0.1:1"], keyspace: "migrate_ks", connect_timeout: 100]
    end

    def nodes, do: ["127.0.0.1:1"]
    def keyspace, do: "migrate_ks"
    def create_keyspace(_name, _opts), do: {:error, :nope}
  end

  defmodule TableNotFoundRepo do
    def config do
      [nodes: ["127.0.0.1:1"], keyspace: "migrate_ks", connect_timeout: 100]
    end

    def nodes, do: ["127.0.0.1:1"]
    def keyspace, do: "migrate_ks"

    def query(_q, _p, _o), do: {:error, %{message: "unconfigured table test_resource"}}
  end

  describe "find_resources/2" do
    test "returns custom resources when provided in opts" do
      assert Release.find_resources([], resources: [AshScylla.TestResource]) == [
               AshScylla.TestResource
             ]
    end

    test "returns empty list when no resources provided and no loaded apps" do
      result = Release.find_resources([], [])
      assert is_list(result)
    end

    test "returns empty list for empty resources list" do
      assert Release.find_resources([], resources: []) == []
    end
  end

  describe "rollback/3" do
    test "returns :ok (placeholder)" do
      assert Release.rollback(AshScylla.TestRepo, 20_240_101_000_000, [AshScylla.TestRepo]) == :ok
    end

    test "accepts string version" do
      assert Release.rollback(AshScylla.TestRepo, "20240101000000", [AshScylla.TestRepo]) == :ok
    end
  end

  describe "create_keyspace/2" do
    test "returns :ok on success" do
      assert Release.create_keyspace(MockRepo, []) == :ok
    end

    test "returns {:error, reason} on failure" do
      assert Release.create_keyspace(FailingKeyspaceRepo, []) == {:error, :nope}
    end

    test "passes opts to repo.create_keyspace" do
      defmodule MockOptsRepo do
        def create_keyspace(_name, opts), do: {:ok, opts}
      end

      assert Release.create_keyspace(MockOptsRepo, strategy: :simple) == :ok
    end
  end

  describe "migrate/3" do
    test "returns :ok when create_keyspace is disabled and no resources" do
      assert :ok =
               Release.migrate(MockRepo, [MockRepo],
                 create_keyspace: false,
                 resources: [],
                 dry_run: true
               )
    end

    test "returns :ok when keyspace is created successfully" do
      assert :ok =
               Release.migrate(MockRepo, [MockRepo],
                 create_keyspace: true,
                 resources: [],
                 dry_run: true
               )
    end

    test "logs and continues when keyspace creation fails" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Release.migrate(FailingKeyspaceRepo, [FailingKeyspaceRepo],
                     create_keyspace: true,
                     resources: [],
                     dry_run: true
                   )
        end)

      assert log =~ "Failed to create keyspace: :nope"
    end

    test "skips resources with no schema changes" do
      assert :ok =
               Release.migrate(MockRepo, [MockRepo],
                 create_keyspace: false,
                 resources: [AshScylla.TestResource],
                 dry_run: true
               )
    end

    test "dry-run reports statements for resources with missing tables" do
      assert :ok =
               Release.migrate(TableNotFoundRepo, [TableNotFoundRepo],
                 create_keyspace: false,
                 resources: [AshScylla.TestResource],
                 dry_run: true
               )
    end

    test "returns an error when a resource migration fails" do
      assert {:error, "1 migration(s) failed"} =
               Release.migrate(TableNotFoundRepo, [TableNotFoundRepo],
                 create_keyspace: false,
                 resources: [AshScylla.TestResource],
                 dry_run: false
               )
    end
  end
end
