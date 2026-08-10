defmodule AshScylla.MixHelpers.MultiDomainTest do
  @moduledoc """
  Unit tests for multi-domain resource/repo discovery via `AshScylla.MixHelpers`.

  `config/test.exs` registers both `AshScylla.TestDomain` and
  `AshScylla.SecondTestDomain` under `:ash_domains`, so discovery must pick up
  resources from both domains.
  """

  use ExUnit.Case, async: true

  alias AshScylla.MixHelpers

  describe "project_domains/0 with multiple domains" do
    test "returns both configured Ash domains" do
      domains = MixHelpers.project_domains()

      assert AshScylla.TestDomain in domains
      assert AshScylla.SecondTestDomain in domains
    end

    test "recognizes every discovered domain as an Ash domain" do
      Enum.each(MixHelpers.project_domains(), fn domain ->
        assert MixHelpers.ash_domain?(domain)
      end)
    end
  end

  describe "find_all_resources/0 with multiple domains" do
    test "discovers resources from both domains" do
      resources = MixHelpers.find_all_resources()

      assert AshScylla.TestResource in resources
      assert AshScylla.SecondTestDomain.Resource in resources
      assert AshScylla.SecondTestDomain.RepoBackedResource in resources
    end

    test "deduplicates resources discovered across domains" do
      resources = MixHelpers.find_all_resources()
      assert resources == Enum.uniq(resources)
    end
  end

  describe "find_default_repo/0 with multiple domains" do
    test "returns the first unique repo across all domains" do
      assert MixHelpers.find_default_repo() == AshScylla.TestRepo
    end
  end
end
