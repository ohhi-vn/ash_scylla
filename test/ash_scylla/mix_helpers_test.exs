defmodule AshScylla.MixHelpersTest do
  use ExUnit.Case, async: true

  alias AshScylla.MixHelpers

  describe "maybe_atomize/2" do
    test "converts string value to module atom" do
      opts = [resource: "MyApp.MyResource"]
      result = MixHelpers.maybe_atomize(opts, :resource)
      assert result[:resource] == MyApp.MyResource
    end

    test "converts dotted string to nested module atom" do
      opts = [domain: "MyApp.MyDomain"]
      result = MixHelpers.maybe_atomize(opts, :domain)
      assert result[:domain] == MyApp.MyDomain
    end

    test "leaves nil values as nil" do
      opts = [dry_run: true]
      result = MixHelpers.maybe_atomize(opts, :resource)
      assert result[:resource] == nil
      assert result[:dry_run] == true
    end

    test "does nothing if key not present" do
      opts = [dry_run: true]
      result = MixHelpers.maybe_atomize(opts, :repo)
      assert result == [dry_run: true]
    end
  end

  describe "file_to_module/1" do
    test "converts lib path to module name" do
      assert MixHelpers.file_to_module("lib/my_app/resources/user.ex") ==
               :"Elixir.MyApp.Resources.User"
    end

    test "handles nested namespaces" do
      assert MixHelpers.file_to_module("lib/my_app/accounts/resources/user.ex") ==
               :"Elixir.MyApp.Accounts.Resources.User"
    end

    test "returns nil for non-lib paths" do
      assert MixHelpers.file_to_module("test/support/fixtures.ex") == nil
    end

    test "returns nil for root-level files" do
      assert MixHelpers.file_to_module("mix.exs") == nil
    end

    test "handles underscore module names" do
      assert MixHelpers.file_to_module("lib/my_app/resources/my_resource.ex") ==
               :"Elixir.MyApp.Resources.MyResource"
    end
  end

  describe "project_lib_paths/0" do
    test "returns a list with at least the current app's lib" do
      paths = MixHelpers.project_lib_paths()
      assert is_list(paths)
      assert "lib" in paths
    end
  end

  describe "project_apps/0" do
    test "returns a list with the current app" do
      apps = MixHelpers.project_apps()
      assert is_list(apps)
      assert :ash_scylla in apps
    end

    test "returns unique apps" do
      apps = MixHelpers.project_apps()
      assert apps == Enum.uniq(apps)
    end
  end

  describe "project_domains/0" do
    test "returns an empty list when no domains configured" do
      domains = MixHelpers.project_domains()
      assert is_list(domains)
    end
  end

  describe "ash_domain?/1" do
    test "returns true for a valid Ash domain" do
      assert MixHelpers.ash_domain?(AshScylla.TestDomain)
    end

    test "returns false for a regular module" do
      refute MixHelpers.ash_domain?(Mix)
    end

    test "returns false for a non-existent module" do
      refute MixHelpers.ash_domain?(NonExistent.Module)
    end

    test "returns false for a resource module (not a domain)" do
      refute MixHelpers.ash_domain?(AshScylla.TestResource)
    end

    test "returns false for an app module (not a domain)" do
      refute MixHelpers.ash_domain?(AshScylla.TestRepo)
    end
  end

  describe "ash_scylla_resource?/1" do
    test "returns false for non-resource modules" do
      refute MixHelpers.ash_scylla_resource?(Mix)
    end

    test "returns false for non-existent modules" do
      refute MixHelpers.ash_scylla_resource?(NonExistent.Module)
    end
  end

  describe "find_all_resources/0" do
    test "returns an empty list when no resources exist" do
      resources = MixHelpers.find_all_resources()
      assert is_list(resources)
    end
  end

  describe "scan_files_for_resources/0" do
    test "returns an empty list when no AshScylla resources exist" do
      resources = MixHelpers.scan_files_for_resources()
      assert is_list(resources)
    end
  end

  describe "app_name/0" do
    test "returns the current app name" do
      assert MixHelpers.app_name() == :ash_scylla
    end
  end
end
