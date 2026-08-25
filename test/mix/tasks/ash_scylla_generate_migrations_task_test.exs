defmodule Mix.Tasks.AshScylla.GenerateMigrationsTaskTest do
  @moduledoc """
  Unit tests for the `mix ash_scylla.generate_migrations` task itself.

  These cover argument parsing (positional name, --domains, --check, flags)
  and delegation to `AshScylla.MigrationGenerator.generate/1`, without
  requiring a running ScyllaDB instance.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @test_tmp_dir "tmp/test_generate_migrations_task"

  setup do
    File.rm_rf!(@test_tmp_dir)
    File.mkdir_p!(@test_tmp_dir)

    on_exit(fn -> File.rm_rf!(@test_tmp_dir) end)

    :ok
  end

  defp base_args do
    [
      "--snapshot-path",
      Path.join(@test_tmp_dir, "snapshots"),
      "--migration-path",
      Path.join(@test_tmp_dir, "migrations")
    ]
  end

  describe "run/1 with --dry-run" do
    test "generates migrations for the given domains" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.GenerateMigrations.run([
            "--dry-run",
            "--domains",
            "AshScylla.TestDomain"
            | base_args()
          ])
        end)

      assert output =~ "Migrations generated for"
      assert output =~ "CREATE TABLE"
      assert output =~ "---"
    end

    test "accepts a positional migration name" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.GenerateMigrations.run([
            "add_users_table",
            "--dry-run",
            "--domains",
            "AshScylla.TestDomain"
            | base_args()
          ])
        end)

      assert output =~ "Migrations generated for"
    end

    test "parses a comma-separated --domains list" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.GenerateMigrations.run([
            "--dry-run",
            "--domains",
            " AshScylla.TestDomain , , AshScylla.SecondTestDomain "
            | base_args()
          ])
        end)

      assert output =~ "Migrations generated for"
    end

    test "does not create files on disk" do
      capture_io(fn ->
        Mix.Tasks.AshScylla.GenerateMigrations.run([
          "--dry-run",
          "--domains",
          "AshScylla.TestDomain"
          | base_args()
        ])
      end)

      refute File.exists?(Path.join(@test_tmp_dir, "migrations"))
      refute File.exists?(Path.join(@test_tmp_dir, "snapshots"))
    end
  end

  describe "run/1 with --check" do
    test "raises PendingCodegen when snapshots are missing" do
      assert_raise Ash.Error.Framework.PendingCodegen, fn ->
        capture_io(fn ->
          Mix.Tasks.AshScylla.GenerateMigrations.run([
            "--check",
            "--domains",
            "AshScylla.TestDomain"
            | base_args()
          ])
        end)
      end
    end
  end

  describe "run/1 writing files" do
    test "--snapshots-only creates snapshots but no migration files" do
      capture_io(fn ->
        Mix.Tasks.AshScylla.GenerateMigrations.run([
          "--snapshots-only",
          "--dev",
          "--quiet",
          "--no-format",
          "--domains",
          "AshScylla.TestDomain"
          | base_args()
        ])
      end)

      snapshot_dir = Path.join([@test_tmp_dir, "snapshots", "test_repo"])

      assert File.dir?(snapshot_dir)
      assert snapshot_dir |> File.ls!() |> Enum.any?(&String.ends_with?(&1, ".json"))
      refute File.exists?(Path.join(@test_tmp_dir, "migrations"))
    end

    test "second run with unchanged schema reports no changes" do
      args = ["--dev", "--snapshots-only", "--domains", "AshScylla.TestDomain" | base_args()]

      capture_io(fn ->
        Mix.Tasks.AshScylla.GenerateMigrations.run(args)
      end)

      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.GenerateMigrations.run(["--quiet" | args])
        end)

      assert output =~ "No changes detected"
    end
  end
end
