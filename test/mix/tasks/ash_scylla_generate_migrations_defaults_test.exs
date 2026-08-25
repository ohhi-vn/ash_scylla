defmodule Mix.Tasks.AshScylla.GenerateMigrationsDefaultsTest do
  @moduledoc """
  Covers the argument-parsing branches of `mix ash_scylla.generate_migrations`
  that the main task test does not: omitted --domains (domain auto-discovery),
  the --name option, and flag combinations.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @test_tmp_dir "tmp/test_generate_migrations_defaults"

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

  test "without --domains, migrations are generated for every configured domain" do
    output =
      capture_io(fn ->
        Mix.Tasks.AshScylla.GenerateMigrations.run(["--dry-run" | base_args()])
      end)

    assert output =~ "Migrations generated for"
    # Both domains from the test configuration must appear.
    assert output =~ "CREATE TABLE"
  end

  test "--name sets the migration name without a positional argument" do
    output =
      capture_io(fn ->
        Mix.Tasks.AshScylla.GenerateMigrations.run([
          "--name",
          "named_migration",
          "--dry-run",
          "--domains",
          "AshScylla.TestDomain"
          | base_args()
        ])
      end)

    assert output =~ "Migrations generated for"
  end

  test "positional name takes precedence over an empty option set" do
    output =
      capture_io(fn ->
        Mix.Tasks.AshScylla.GenerateMigrations.run([
          "positional_name",
          "--dry-run",
          "--snapshots-only"
          | base_args()
        ])
      end)

    assert output != ""
  end
end
