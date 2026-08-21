defmodule AshScyllaTest do
  use ExUnit.Case, async: true

  alias AshScylla.{TestRepo, TestResource, TestResourceNoKeyspace}

  defmodule MigrateMockRepo do
    def config do
      [nodes: ["127.0.0.1:1"], keyspace: "migrate_ks", connect_timeout: 100]
    end

    def nodes, do: ["127.0.0.1:1"]
    def keyspace, do: "migrate_ks"
    def create_keyspace(_name, _opts), do: {:ok, %{}}
    def query(_q, _p, _o), do: {:error, "boom"}
  end

  defmodule FailingKeyspaceRepo do
    def config, do: []
    def create_keyspace(_name, _opts), do: {:error, :nope}
  end

  describe "version/0" do
    test "returns a non-empty version string" do
      version = AshScylla.version()
      assert is_binary(version)
      assert version != ""
    end

    test "returns a valid version format" do
      version = AshScylla.version()
      assert String.match?(version, ~r/^\d+\.\d+\.\d+/)
    end
  end

  describe "verify/2" do
    defmodule MissingConfigRepo do
    end

    defmodule InvalidConfigRepo do
      def config, do: :not_a_list
    end

    defmodule FailingConfigRepo do
      def config, do: raise("boom")
    end

    test "returns an error for a non-atom repo" do
      assert {:error, {:invalid_repo, "bad"}} = AshScylla.verify("bad", check_connection?: false)
    end

    test "returns an error for an unloaded repo module" do
      assert {:error, {:repo_not_loaded, :NoSuchRepo}} =
               AshScylla.verify(:NoSuchRepo, check_connection?: false)
    end

    test "returns an error when repo lacks config/0" do
      assert {:error, {:repo_missing_config, MissingConfigRepo}} =
               AshScylla.verify(MissingConfigRepo, check_connection?: false)
    end

    test "returns an error for invalid repo config" do
      assert {:error, {:invalid_repo_config, InvalidConfigRepo, :not_a_list}} =
               AshScylla.verify(InvalidConfigRepo, check_connection?: false)
    end

    test "returns an error when repo config raises" do
      assert {:error, {:repo_config_failed, FailingConfigRepo, _}} =
               AshScylla.verify(FailingConfigRepo, check_connection?: false)
    end

    test "returns an error for invalid nodes" do
      assert {:error, {:invalid_nodes, 123}} =
               AshScylla.verify(TestRepo, nodes: 123, check_connection?: false)
    end

    test "returns an error for empty nodes" do
      assert {:error, :no_nodes} =
               AshScylla.verify(TestRepo, nodes: [], check_connection?: false)
    end

    test "accepts a single binary node string" do
      assert {:ok, _} =
               AshScylla.verify(TestRepo, nodes: "127.0.0.1:9051", check_connection?: false)
    end

    test "returns an error for invalid keyspace" do
      assert {:error, {:invalid_keyspace, "bad keyspace"}} =
               AshScylla.verify(TestRepo, keyspace: "bad keyspace", check_connection?: false)
    end

    test "returns an error for invalid resources" do
      assert {:error, {:invalid_resources, :bad}} =
               AshScylla.verify(TestRepo, resources: :bad, check_connection?: false)
    end

    test "returns ok with connection check disabled" do
      assert {:ok, report} = AshScylla.verify(TestRepo, check_connection?: false)
      assert report.repo == TestRepo
      assert report.nodes == TestRepo.nodes()
      assert report.keyspace == TestRepo.keyspace()
      assert report.connection == %{checked?: false, release_version: :skipped}

      assert report.keyspace_report == %{
               name: TestRepo.keyspace(),
               checked?: false,
               exists?: nil
             }

      assert report.resources == []
    end

    test "verifies resources without a connection" do
      assert {:ok, report} =
               AshScylla.verify(TestRepo, check_connection?: false, resources: [TestResource])

      assert [resource_report] = report.resources
      assert resource_report.resource == TestResource
      assert resource_report.keyspace == "ash_scylla_test"
      assert resource_report.table == "test_resource"
      assert resource_report.checked? == false
      assert resource_report.exists? == nil
    end

    test "resource without keyspace falls back to repo keyspace" do
      assert {:ok, report} =
               AshScylla.verify(TestRepo,
                 check_connection?: false,
                 resources: [TestResourceNoKeyspace]
               )

      assert [%{resource: TestResourceNoKeyspace, keyspace: keyspace}] = report.resources
      assert keyspace == TestRepo.keyspace()
    end

    test "returns an error when resource and repo both lack a keyspace" do
      assert {:error, {:missing_keyspace, TestResourceNoKeyspace}} =
               AshScylla.verify(TestRepo,
                 keyspace: nil,
                 check_connection?: false,
                 resources: [TestResourceNoKeyspace]
               )
    end

    test "nil keyspace produces an empty keyspace report" do
      assert {:ok, report} = AshScylla.verify(TestRepo, keyspace: nil, check_connection?: false)
      assert report.keyspace == nil
      assert report.keyspace_report.name == nil
    end

    test "resource with its own keyspace overrides nil repo keyspace" do
      assert {:ok, report} =
               AshScylla.verify(TestRepo,
                 keyspace: nil,
                 check_connection?: false,
                 resources: [TestResource]
               )

      assert [%{keyspace: "ash_scylla_test"}] = report.resources
    end

    test "rejects a non-binary keyspace" do
      assert {:error, {:invalid_keyspace, 123}} =
               AshScylla.verify(TestRepo, keyspace: 123, check_connection?: false)
    end
  end

  describe "verify!/2" do
    test "raises on error" do
      assert_raise RuntimeError, ~r/AshScylla verification failed/, fn ->
        AshScylla.verify!(TestRepo, nodes: 123, check_connection?: false)
      end
    end

    test "returns report on success" do
      assert %{repo: TestRepo} = AshScylla.verify!(TestRepo, check_connection?: false)
    end
  end

  describe "migrate/2" do
    test "delegates to Release.migrate and returns :ok for dry run with no resources" do
      assert :ok =
               AshScylla.migrate(MigrateMockRepo,
                 resources: [],
                 create_keyspace: false,
                 dry_run: true
               )
    end
  end

  describe "create_keyspace/2" do
    test "returns :ok when repo create_keyspace succeeds" do
      assert :ok = AshScylla.create_keyspace(MigrateMockRepo, [])
    end

    test "returns an error when repo create_keyspace fails" do
      assert {:error, :nope} = AshScylla.create_keyspace(FailingKeyspaceRepo, [])
    end
  end
end
