defmodule AshScylla.DataLayer.MultiDomainTest do
  @moduledoc """
  Unit tests for multi-domain scenarios.

  Verifies that the data layer, DSL config, and keyspace/table resolution behave
  correctly when an application registers more than one Ash domain, where each
  domain may have its own resources, repos, and keyspaces.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.Dsl
  alias AshScylla.DataLayer.SchemaUtils

  @domain_a AshScylla.TestDomain
  @domain_b AshScylla.SecondTestDomain

  # ── Same-short-name resources in different domains ────────────────────────

  defmodule DomainA do
    use Ash.Domain, otp_app: :ash_scylla, validate_config_inclusion?: false

    resources do
      resource(AshScylla.MultiDomainTest.DomainA.Stats)
    end
  end

  defmodule DomainB do
    use Ash.Domain, otp_app: :ash_scylla, validate_config_inclusion?: false

    resources do
      resource(AshScylla.MultiDomainTest.DomainB.Stats)
    end
  end

  defmodule DomainA.Stats do
    use Ash.Resource,
      domain: AshScylla.MultiDomainTest.DomainA,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(AshScylla.TestRepo)
      keyspace("ash_scylla_test")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule DomainB.Stats do
    use Ash.Resource,
      domain: AshScylla.MultiDomainTest.DomainB,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(AshScylla.TestRepo)
      keyspace("ash_scylla_second_test")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  # ── Domain/resource ownership ──────────────────────────────────────────────

  describe "resource ownership" do
    test "resources belong to their own domains" do
      assert Ash.Resource.Info.domain(AshScylla.TestResource) == @domain_a
      assert Ash.Resource.Info.domain(AshScylla.SecondTestDomain.Resource) == @domain_b
      assert Ash.Resource.Info.domain(AshScylla.SecondTestDomain.RepoBackedResource) == @domain_b
    end

    test "each domain only lists its own resources" do
      domain_a_resources = Ash.Domain.Info.resources(@domain_a)
      domain_b_resources = Ash.Domain.Info.resources(@domain_b)

      assert AshScylla.TestResource in domain_a_resources
      refute AshScylla.SecondTestDomain.Resource in domain_a_resources
      refute AshScylla.SecondTestDomain.RepoBackedResource in domain_a_resources

      assert AshScylla.SecondTestDomain.Resource in domain_b_resources
      assert AshScylla.SecondTestDomain.RepoBackedResource in domain_b_resources
      refute AshScylla.TestResource in domain_b_resources
    end

    test "resources in both domains use the AshScylla data layer" do
      assert Ash.Resource.Info.data_layer(AshScylla.TestResource) == DataLayer
      assert Ash.Resource.Info.data_layer(AshScylla.SecondTestDomain.Resource) == DataLayer

      assert Ash.Resource.Info.data_layer(AshScylla.SecondTestDomain.RepoBackedResource) ==
               DataLayer
    end
  end

  # ── DSL config per domain ─────────────────────────────────────────────────

  describe "DSL configuration per domain" do
    test "domain A resource uses its own repo, keyspace, and table" do
      assert Dsl.repo(AshScylla.TestResource) == AshScylla.TestRepo
      assert Dsl.keyspace(AshScylla.TestResource) == "ash_scylla_test"
      assert Dsl.table(AshScylla.TestResource) == "test_resource"
      assert Dsl.consistency(AshScylla.TestResource) == :one
    end

    test "domain B resource overrides keyspace while sharing the repo" do
      assert Dsl.repo(AshScylla.SecondTestDomain.Resource) == AshScylla.TestRepo
      assert Dsl.keyspace(AshScylla.SecondTestDomain.Resource) == "ash_scylla_second_test"
      assert Dsl.table(AshScylla.SecondTestDomain.Resource) == "second_domain_resources"
    end

    test "domain B repo-backed resource resolves keyspace from its own repo" do
      assert Dsl.repo(AshScylla.SecondTestDomain.RepoBackedResource) == AshScylla.SecondTestRepo
      assert Dsl.keyspace(AshScylla.SecondTestDomain.RepoBackedResource) == nil
      assert AshScylla.SecondTestRepo.keyspace() == "ash_scylla_second_repo_test"
    end
  end

  # ── Keyspace resolution ───────────────────────────────────────────────────

  describe "keyspace resolution across domains" do
    test "resource-level keyspace wins over repo-level keyspace" do
      assert DataLayer.qualified_table(AshScylla.TestResource) == "ash_scylla_test.test_resource"

      assert DataLayer.qualified_table(AshScylla.SecondTestDomain.Resource) ==
               "ash_scylla_second_test.second_domain_resources"
    end

    test "repo-level keyspace is used when a resource has no DSL keyspace" do
      assert DataLayer.qualified_table(AshScylla.SecondTestDomain.RepoBackedResource) ==
               "ash_scylla_second_repo_test.repo_backed_resources"
    end

    test "qualified_table distinguishes domains with the same keyspace" do
      # Two resources in different domains, same repo + keyspace, still get
      # distinct keyspace-qualified tables because their table names differ.
      refute DataLayer.qualified_table(AshScylla.TestResource) ==
               DataLayer.qualified_table(AshScylla.SecondTestDomain.Resource)
    end
  end

  # ── resource_to_query ─────────────────────────────────────────────────────

  describe "resource_to_query/2 across domains" do
    test "builds per-domain queries with the correct repo and qualified table" do
      query_a = DataLayer.resource_to_query(AshScylla.TestResource, @domain_a)
      assert query_a.repo == AshScylla.TestRepo
      assert query_a.table == "ash_scylla_test.test_resource"

      query_b = DataLayer.resource_to_query(AshScylla.SecondTestDomain.Resource, @domain_b)
      assert query_b.repo == AshScylla.TestRepo
      assert query_b.table == "ash_scylla_second_test.second_domain_resources"

      query_c =
        DataLayer.resource_to_query(AshScylla.SecondTestDomain.RepoBackedResource, @domain_b)

      assert query_c.repo == AshScylla.SecondTestRepo
      assert query_c.table == "ash_scylla_second_repo_test.repo_backed_resources"
    end
  end

  # ── Same-short-name collision avoidance ───────────────────────────────────

  describe "same-short-name resources across domains" do
    test "derive distinct table names when no explicit table is set" do
      assert DataLayer.resolve_table_name(DomainA.Stats) == "domain_a_stats"
      assert DataLayer.resolve_table_name(DomainB.Stats) == "domain_b_stats"

      assert SchemaUtils.get_table_name(DomainA.Stats) == "domain_a_stats"
      assert SchemaUtils.get_table_name(DomainB.Stats) == "domain_b_stats"
    end

    test "keyspace resolution stays correct for same-short-name resources" do
      assert DataLayer.qualified_table(DomainA.Stats) == "ash_scylla_test.domain_a_stats"
      assert DataLayer.qualified_table(DomainB.Stats) == "ash_scylla_second_test.domain_b_stats"
    end
  end

  # ── Multitenancy across domains ───────────────────────────────────────────

  describe "set_tenant/3 across domains" do
    test "stores the tenant on queries for any domain's resource" do
      query = DataLayer.resource_to_query(AshScylla.SecondTestDomain.Resource, @domain_b)
      assert {:ok, %{tenant: "org_123"}} = DataLayer.set_tenant(nil, query, "org_123")

      query_a = DataLayer.resource_to_query(AshScylla.TestResource, @domain_a)

      assert {:ok, %{tenant: "org_456"}} =
               DataLayer.set_tenant(AshScylla.TestResource, query_a, "org_456")
    end

    test "works for repo-backed resources in the second domain" do
      query =
        DataLayer.resource_to_query(AshScylla.SecondTestDomain.RepoBackedResource, @domain_b)

      assert {:ok, %{tenant: "org_789"}} =
               DataLayer.set_tenant(
                 AshScylla.SecondTestDomain.RepoBackedResource,
                 query,
                 "org_789"
               )
    end
  end
end
