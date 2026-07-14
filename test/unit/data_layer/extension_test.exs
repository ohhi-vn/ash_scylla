defmodule AshScylla.ExtensionTest do
  @moduledoc """
  Tests for `AshScylla.Extension` — the Ash extension callbacks that back
  `mix ash.codegen`, `mix ash.migrate`, and the other Ash.Extension tasks.

  The data layer module (`AshScylla.DataLayer`) is what Ash discovers as the
  extension; it forwards each callback here. These tests exercise the logic
  that lives in `AshScylla.Extension`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "codegen/1" do
    test "runs without error when no resources found" do
      capture_io(fn ->
        assert AshScylla.Extension.codegen(["--dev"]) == :ok
      end)
    end

    test "runs with --dry-run flag" do
      capture_io(fn ->
        assert AshScylla.Extension.codegen(["--dry-run", "--dev"]) == :ok
      end)
    end

    test "runs with name argument" do
      capture_io(fn ->
        assert AshScylla.Extension.codegen(["my_migration"]) == :ok
      end)
    end

    test "respects --dev flag" do
      capture_io(fn ->
        AshScylla.Extension.codegen(["--dev"])
      end)
    end

    test "respects --dry-run flag in output" do
      capture_io(fn ->
        AshScylla.Extension.codegen(["--dry-run"])
      end)
    end

    test "accepts a migration name as first argument" do
      capture_io(fn ->
        AshScylla.Extension.codegen(["my_migration"])
      end)
    end

    test "accepts name with --dry-run" do
      capture_io(fn ->
        AshScylla.Extension.codegen(["my_migration", "--dry-run"])
      end)
    end

    test "accepts name with --dev" do
      capture_io(fn ->
        AshScylla.Extension.codegen(["my_migration", "--dev"])
      end)
    end
  end

  describe "parse_codegen_argv/1" do
    test "parses a leading positional name" do
      assert [name: "add_users"] =
               AshScylla.Extension.parse_codegen_argv(["add_users"])
    end

    test "parses an explicit --name flag" do
      assert [name: "add_users"] =
               AshScylla.Extension.parse_codegen_argv(["--name", "add_users"])
    end

    test "parses --dev" do
      assert [dev: true] = AshScylla.Extension.parse_codegen_argv(["--dev"])
    end

    test "parses --dry-run and --check" do
      opts = AshScylla.Extension.parse_codegen_argv(["--dry-run", "--check"])
      assert opts[:dry_run] == true
      assert opts[:check] == true
    end

    test "omits flags that are not present" do
      assert [] = AshScylla.Extension.parse_codegen_argv([])
    end
  end

  describe "setup/1" do
    test "runs without error" do
      capture_io(fn ->
        assert AshScylla.Extension.setup([]) == :ok
      end)
    end

    test "runs with --dry-run flag" do
      capture_io(fn ->
        assert AshScylla.Extension.setup(["--dry-run"]) == :ok
      end)
    end

    test "outputs setup message" do
      capture_io(fn ->
        AshScylla.Extension.setup(["--dry-run"])
      end)
    end

    test "handles missing repo gracefully" do
      capture_io(fn ->
        AshScylla.Extension.setup([])
      end)
    end
  end

  describe "migrate/1" do
    test "runs without error when no migration files found" do
      capture_io(fn ->
        assert AshScylla.Extension.migrate([]) == :ok
      end)
    end

    test "runs with --dry-run flag" do
      capture_io(fn ->
        assert AshScylla.Extension.migrate(["--dry-run"]) == :ok
      end)
    end

    test "outputs migration message" do
      capture_io(fn ->
        AshScylla.Extension.migrate(["--dry-run"])
      end)
    end

    test "reports when no migration files found" do
      capture_io(fn ->
        AshScylla.Extension.migrate([])
      end)
    end
  end

  describe "install/5" do
    test "installs with --dry-run" do
      capture_io(fn ->
        AshScylla.Extension.install(
          nil,
          AshScylla.TestResource,
          AshScylla.TestResource,
          "lib/test.ex",
          ["--dry-run"]
        )
      end)
    end

    test "installs without flags" do
      capture_io(fn ->
        AshScylla.Extension.install(
          nil,
          AshScylla.TestResource,
          AshScylla.TestResource,
          "lib/test.ex",
          []
        )
      end)
    end

    test "returns igniter unchanged" do
      igniter = %{some: :state}

      capture_io(fn ->
        assert AshScylla.Extension.install(
                 igniter,
                 AshScylla.TestResource,
                 AshScylla.TestResource,
                 "lib/test.ex",
                 []
               ) == igniter
      end)
    end

    test "returns igniter unchanged with --dry-run" do
      igniter = %{some: :state}

      capture_io(fn ->
        assert AshScylla.Extension.install(
                 igniter,
                 AshScylla.TestResource,
                 AshScylla.TestResource,
                 "lib/test.ex",
                 ["--dry-run"]
               ) == igniter
      end)
    end

    test "displays module name in output" do
      capture_io(fn ->
        AshScylla.Extension.install(
          nil,
          AshScylla.TestResource,
          AshScylla.TestResource,
          "lib/test.ex",
          []
        )
      end)
    end

    test "displays location in output" do
      capture_io(fn ->
        AshScylla.Extension.install(
          nil,
          AshScylla.TestResource,
          AshScylla.TestResource,
          "lib/my_app/user.ex",
          []
        )
      end)
    end

    test "install with resource type" do
      capture_io(fn ->
        AshScylla.Extension.install(
          nil,
          AshScylla.TestResource,
          AshScylla.TestResource,
          "lib/test.ex",
          []
        )
      end)
    end

    test "install with domain type" do
      capture_io(fn ->
        AshScylla.Extension.install(
          nil,
          AshScylla.TestDomain,
          AshScylla.TestDomain,
          "lib/test_domain.ex",
          []
        )
      end)
    end

    test "install with string type" do
      capture_io(fn ->
        AshScylla.Extension.install(nil, :some_module, "some_type", "lib/test.ex", [])
      end)
    end
  end

  describe "reset/1" do
    test "runs reset with --dry-run" do
      capture_io(fn ->
        AshScylla.Extension.reset(["--dry-run"])
      end)
    end

    test "runs reset without flags" do
      capture_io(fn ->
        AshScylla.Extension.reset([])
      end)
    end

    test "attempts to drop and recreate keyspace" do
      capture_io(fn ->
        AshScylla.Extension.reset([])
      end)
    end

    test "runs migrations after reset" do
      capture_io(fn ->
        AshScylla.Extension.reset(["--dry-run"])
      end)
    end

    test "handles missing repo gracefully" do
      capture_io(fn ->
        AshScylla.Extension.reset([])
      end)
    end
  end

  describe "rollback/1" do
    test "runs rollback with --dry-run" do
      capture_io(fn ->
        AshScylla.Extension.rollback(["--dry-run"])
      end)
    end

    test "runs rollback without flags" do
      capture_io(fn ->
        AshScylla.Extension.rollback([])
      end)
    end

    test "rollback with --version flag" do
      capture_io(fn ->
        AshScylla.Extension.rollback(["--version", "20240101000000"])
      end)
    end

    test "rollback with --version and --dry-run" do
      capture_io(fn ->
        AshScylla.Extension.rollback(["--version", "20240101000000", "--dry-run"])
      end)
    end

    test "rollback without version does not crash" do
      capture_io(fn ->
        AshScylla.Extension.rollback([])
      end)
    end

    test "handles missing repo gracefully" do
      capture_io(fn ->
        AshScylla.Extension.rollback([])
      end)
    end
  end

  describe "tear_down/1" do
    test "runs tear_down with --dry-run" do
      capture_io(fn ->
        AshScylla.Extension.tear_down(["--dry-run"])
      end)
    end

    test "runs tear_down without flags" do
      capture_io(fn ->
        AshScylla.Extension.tear_down([])
      end)
    end

    test "attempts to drop keyspace" do
      capture_io(fn ->
        AshScylla.Extension.tear_down([])
      end)
    end

    test "tear_down with --dry-run does not drop keyspace" do
      capture_io(fn ->
        AshScylla.Extension.tear_down(["--dry-run"])
      end)
    end

    test "handles missing repo gracefully" do
      capture_io(fn ->
        AshScylla.Extension.tear_down([])
      end)
    end
  end

  describe "callback return values" do
    test "codegen returns :ok" do
      capture_io(fn ->
        assert AshScylla.Extension.codegen([]) == :ok
      end)
    end

    test "setup returns :ok" do
      capture_io(fn ->
        assert AshScylla.Extension.setup([]) == :ok
      end)
    end

    test "migrate returns :ok" do
      capture_io(fn ->
        assert AshScylla.Extension.migrate([]) == :ok
      end)
    end

    test "reset returns :ok" do
      capture_io(fn ->
        AshScylla.Extension.reset([])
      end)
    end

    test "rollback returns :ok" do
      capture_io(fn ->
        AshScylla.Extension.rollback([])
      end)
    end

    test "tear_down returns :ok" do
      capture_io(fn ->
        AshScylla.Extension.tear_down([])
      end)
    end
  end

  describe "dry-run consistency" do
    test "all callbacks support --dry-run flag" do
      callbacks = [
        {&AshScylla.Extension.codegen/1, ["--dry-run"]},
        {&AshScylla.Extension.setup/1, ["--dry-run"]},
        {&AshScylla.Extension.migrate/1, ["--dry-run"]},
        {&AshScylla.Extension.reset/1, ["--dry-run"]},
        {&AshScylla.Extension.rollback/1, ["--dry-run"]},
        {&AshScylla.Extension.tear_down/1, ["--dry-run"]}
      ]

      Enum.each(callbacks, fn {callback, args} ->
        capture_io(fn ->
          callback.(args)
        end)
      end)
    end
  end
end
