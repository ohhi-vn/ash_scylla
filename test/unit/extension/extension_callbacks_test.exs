defmodule AshScylla.ExtensionCallbacksTest do
  @moduledoc """
  Covers AshScylla.Extension codegen/setup/migrate/reset/rollback/tear_down
  callbacks without a live ScyllaDB. Connection-bound paths run against the
  unreachable node 127.0.0.1:59999 (fails fast).
  """

  use ExUnit.Case, async: false

  alias AshScylla.Extension

  @unreachable [nodes: ["127.0.0.1:59999"], keyspace: "ash_scylla_dev", connect_timeout: 100]

  setup do
    original_repo_env = Application.get_env(:ash_scylla, AshScylla.TestRepo)
    original_domains = Application.get_env(:ash_scylla, :ash_domains)

    # Keep every connection attempt fast and hermetic.
    Application.put_env(:ash_scylla, AshScylla.TestRepo, @unreachable)

    on_exit(fn ->
      if original_repo_env == nil do
        Application.delete_env(:ash_scylla, AshScylla.TestRepo)
      else
        Application.put_env(:ash_scylla, AshScylla.TestRepo, original_repo_env)
      end

      if original_domains == nil do
        Application.delete_env(:ash_scylla, :ash_domains)
      else
        Application.put_env(:ash_scylla, :ash_domains, original_domains)
      end
    end)

    # Route Mix.shell output into the test mailbox for easy assertions.
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(original_shell) end)

    :ok
  end

  defp with_no_repos(fun) do
    Application.put_env(:ash_scylla, :ash_domains, [])
    fun.()
  end

  defp collect_shell do
    collect_shell([])
  end

  defp collect_shell(acc) do
    receive do
      {:mix_shell, kind, [msg | _]} -> collect_shell([{kind, msg} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  describe "parse_codegen_argv/1" do
    test "leading positional name wins over --name flag" do
      opts = Extension.parse_codegen_argv(["add_index", "--name", "other"])

      assert opts[:name] == "add_index"
    end

    test "extracts --name when no positional argument is present" do
      opts = Extension.parse_codegen_argv(["--name", "later", "--dev"])

      assert opts[:name] == "later"
      assert opts[:dev] == true
      assert opts[:dry_run] == nil
    end

    test "collects shared flags" do
      opts = Extension.parse_codegen_argv(["--dry-run", "--check", "--force"])

      assert opts[:dry_run] and opts[:check] and opts[:force]
      assert opts[:name] == nil
    end
  end

  describe "setup/1" do
    test "creates keyspace best-effort then runs migrations" do
      assert Extension.setup([]) == :ok
      messages = collect_shell()

      assert {:info, "Setting up AshScylla..."} in messages
      assert {:info, "  Creating keyspace ash_scylla_dev..."} in messages
      assert Enum.any?(messages, fn {kind, msg} -> kind == :info and msg =~ "Running" end)
    end

    test "dry-run only reports intended actions" do
      assert Extension.setup(["--dry-run"]) == :ok
      messages = collect_shell()

      assert {:info, "  [DRY RUN] Would create keyspace ash_scylla_dev"} in messages
      assert Enum.any?(messages, fn {_kind, msg} -> msg =~ "[DRY RUN]" end)
    end

    test "skips keyspace creation when no repo is configured" do
      with_no_repos(fn ->
        assert Extension.setup([]) == :ok
      end)

      messages = collect_shell()
      assert {:info, "  No repo configured, skipping keyspace creation."} in messages
    end
  end

  describe "migrate/1" do
    test "auto-creates keyspace and reports per-statement failures against unreachable nodes" do
      assert Extension.migrate([]) == :ok
      messages = collect_shell()

      assert {:info, "  Ensuring keyspace ash_scylla_dev exists..."} in messages
      assert Enum.any?(messages, fn {kind, msg} -> kind == :error and msg =~ "FAILED" end)
    end

    test "dry-run lists statements without executing them" do
      assert Extension.migrate(["--dry-run"]) == :ok
      messages = collect_shell()

      assert {:info, "  [DRY RUN] Would create keyspace ash_scylla_dev"} in messages
      assert Enum.any?(messages, fn {_kind, msg} -> msg =~ "[DRY RUN]" and msg =~ ".exs" end)
    end

    test "reports migrations that cannot run without a configured repo" do
      root = unique_tmp("fvx_ext_norepo")
      mig_dir = Path.join([root, "priv", "repo", "migrations"])
      File.mkdir_p!(mig_dir)

      File.write!(Path.join(mig_dir, "20260101000000_fvx_good.exs"), """
      defmodule Fvx.ExtGood#{System.unique_integer([:positive])} do
        use AshScylla.Schema

        def change, do: ["CREATE TABLE fvx_ext (id uuid PRIMARY KEY)"]
      end
      """)

      original_cwd = File.cwd!()
      File.cd!(root)

      try do
        with_no_repos(fn ->
          assert Extension.migrate([]) == :ok
        end)

        messages = collect_shell()

        assert Enum.any?(messages, fn {kind, msg} ->
                 kind == :error and msg =~ "Cannot run migration" and msg =~ "no repo configured"
               end)
      after
        File.cd!(original_cwd)
      end
    end

    test "skips non-schema files and warns about unloadable ones" do
      root = unique_tmp("fvx_ext_badfiles")
      mig_dir = Path.join([root, "priv", "repo", "migrations"])
      File.mkdir_p!(mig_dir)

      File.write!(Path.join(mig_dir, "20260101000001_fvx_not_schema.exs"), """
      defmodule Fvx.ExtNotSchema#{System.unique_integer([:positive])} do
        def change, do: ["SELECT 1"]
      end
      """)

      File.write!(Path.join(mig_dir, "broken.exs"), "this is not a defmodule")

      original_cwd = File.cwd!()
      File.cd!(root)

      log =
        try do
          with_no_repos(fn ->
            ExUnit.CaptureLog.capture_log(fn ->
              assert Extension.migrate([]) == :ok
            end)
          end)
        after
          File.cd!(original_cwd)
        end

      assert log =~ "Failed to load migration"
      assert log =~ ":no_module_found"
      messages = collect_shell()
      assert Enum.any?(messages, fn {_kind, msg} -> msg =~ "Running 2 migration file(s)" end)
    end
  end

  describe "reset/1" do
    test "dry-run reports drop and recreate without touching a database" do
      assert Extension.reset(["--dry-run"]) == :ok
      messages = collect_shell()

      assert {:info, "Resetting AshScylla..."} in messages
      assert {:info, "  [DRY RUN] Would drop keyspace ash_scylla_dev"} in messages
      assert {:info, "  [DRY RUN] Would recreate keyspace ash_scylla_dev"} in messages
    end

    test "drops and recreates best-effort when the database is unreachable" do
      assert Extension.reset([]) == :ok
      messages = collect_shell()

      assert {:info, "  Keyspace ash_scylla_dev dropped."} in messages
      assert {:info, "  Recreating keyspace ash_scylla_dev..."} in messages
      assert {:info, "  Keyspace ash_scylla_dev recreated."} in messages
    end

    test "skips reset when no repo is configured" do
      with_no_repos(fn ->
        assert Extension.reset([]) == :ok
      end)

      messages = collect_shell()
      assert {:info, "  No repo configured, skipping keyspace reset."} in messages
    end
  end

  describe "rollback/1" do
    test "dry-run prints the target version and CQL caveat" do
      assert Extension.rollback(["--dry-run", "--version", "20240101"]) == :ok
      messages = collect_shell()

      assert {:info, "Rolling back AshScylla..."} in messages
      assert {:info, "  Target version: 20240101"} in messages

      assert {:info, "  [DRY RUN] Note: CQL does not support transactional DDL rollback"} in messages
    end

    test "non dry-run delegates to Release.rollback which is a logged no-op" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Extension.rollback(["--version", "42"]) == :ok
        end)

      messages = collect_shell()
      assert {:info, "  Target version: 42"} in messages
      assert log =~ "Rolling back"
    end

    test "skips rollback when no repo is configured" do
      with_no_repos(fn ->
        assert Extension.rollback([]) == :ok
      end)

      messages = collect_shell()
      assert {:info, "  No repo configured, skipping rollback."} in messages
    end
  end

  describe "tear_down/1" do
    test "dry-run reports dropping the keyspace" do
      assert Extension.tear_down(["--dry-run"]) == :ok
      messages = collect_shell()

      assert {:info, "Tearing down AshScylla..."} in messages
      assert {:info, "  [DRY RUN] Would drop keyspace ash_scylla_dev"} in messages
    end

    test "drops best-effort when the database is unreachable" do
      assert Extension.tear_down([]) == :ok
      messages = collect_shell()

      assert {:info, "  Dropping keyspace ash_scylla_dev..."} in messages
      assert {:info, "  Keyspace ash_scylla_dev dropped."} in messages
    end

    test "skips teardown when no repo is configured" do
      with_no_repos(fn ->
        assert Extension.tear_down([]) == :ok
      end)

      messages = collect_shell()
      assert {:info, "  No repo configured, skipping teardown."} in messages
    end
  end

  describe "install/4" do
    test "reports installation details and returns the igniter unchanged" do
      igniter =
        Extension.install(
          :igniter_stub,
          Fvx.InstallTargetRepo,
          Fvx.InstallTargetRepo,
          "lib/fvx/repo.ex",
          []
        )

      assert igniter == :igniter_stub
      messages = collect_shell()

      assert Enum.any?(messages, fn {kind, msg} ->
               kind == :info and msg =~ "Installing AshScylla for Fvx.InstallTargetRepo"
             end)

      assert Enum.any?(messages, fn {kind, msg} ->
               kind == :info and msg =~ "Type: InstallTargetRepo"
             end)
    end

    test "dry-run install does nothing but returns the igniter" do
      assert Extension.install(
               :igniter_stub,
               Fvx.InstallTargetRepo,
               Fvx.InstallTargetRepo,
               "lib/repo.ex",
               [
                 "--dry-run"
               ]
             ) == :igniter_stub

      messages = collect_shell()

      assert Enum.any?(messages, fn {_kind, msg} ->
               msg =~ "[DRY RUN] Would install AshScylla configuration"
             end)
    end
  end

  defp unique_tmp(prefix) do
    path = Path.expand(Path.join(["tmp", "#{prefix}_#{System.unique_integer([:positive])}"]))
    File.mkdir_p!(path)

    on_exit(fn -> File.rm_rf(path) end)

    path
  end
end
