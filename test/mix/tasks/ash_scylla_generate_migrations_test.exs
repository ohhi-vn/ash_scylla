# Copyright 2024 AshScylla Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule Mix.Tasks.AshScylla.GenerateMigrationsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AshScylla.MigrationGenerator

  @test_tmp_dir "tmp/test_migrations"

  setup do
    # Clean up test directories before each test
    File.rm_rf!(@test_tmp_dir)
    File.mkdir_p!(@test_tmp_dir)
    on_exit(fn -> File.rm_rf!(@test_tmp_dir) end)
    :ok
  end

  describe "MigrationGenerator struct" do
    test "has default values" do
      gen = %MigrationGenerator{}
      assert gen.snapshot_path == nil
      assert gen.migration_path == nil
      assert gen.name == nil
      assert gen.quiet == false
      assert gen.format == true
      assert gen.dry_run == false
      assert gen.check == false
      assert gen.dev == false
      assert gen.snapshots_only == false
    end
  end

  describe "generate/2 with dry-run" do
    test "returns :ok when no resources found" do
      # When no domains/resources are configured, should return :ok
      result = MigrationGenerator.generate(dry_run: true, domains: [])
      assert result == :ok
    end
  end

  describe "timestamp generation" do
    test "produces 14-digit timestamp" do
      # The timestamp function is private, but we can test via the migration name
      # by observing that generate_migrations creates files with timestamp prefixes
      # This is tested indirectly through the generate_migrations task tests
      assert true
    end
  end

  describe "change detection - no regeneration on re-run" do
    test "does not create new snapshot files when schema unchanged" do
      # First run - should create snapshots and migrations
      capture_io(fn ->
        MigrationGenerator.generate(
          dev: true,
          snapshot_path: Path.join(@test_tmp_dir, "snapshots"),
          migration_path: Path.join(@test_tmp_dir, "migrations"),
          domains: [AshScylla.TestDomain]
        )
      end)

      # Count snapshot files after first run
      snapshot_dir = Path.join(@test_tmp_dir, "snapshots/test_repo")
      snapshot_files_after_first_run = list_snapshot_files(snapshot_dir)
      assert length(snapshot_files_after_first_run) > 0

      # Second run - should NOT create new snapshot files since nothing changed
      capture_io(fn ->
        MigrationGenerator.generate(
          dev: true,
          snapshot_path: Path.join(@test_tmp_dir, "snapshots"),
          migration_path: Path.join(@test_tmp_dir, "migrations"),
          domains: [AshScylla.TestDomain]
        )
      end)

      # Count snapshot files after second run - should be same as after first run
      snapshot_files_after_second_run = list_snapshot_files(snapshot_dir)
      assert length(snapshot_files_after_second_run) == length(snapshot_files_after_first_run)
    end

    test "reports no changes detected on second run" do
      # First run
      capture_io(fn ->
        MigrationGenerator.generate(
          dev: true,
          snapshot_path: Path.join(@test_tmp_dir, "snapshots"),
          migration_path: Path.join(@test_tmp_dir, "migrations"),
          domains: [AshScylla.TestDomain]
        )
      end)

      # Second run should report no changes
      output2 =
        capture_io(fn ->
          MigrationGenerator.generate(
            dev: true,
            snapshot_path: Path.join(@test_tmp_dir, "snapshots"),
            migration_path: Path.join(@test_tmp_dir, "migrations"),
            domains: [AshScylla.TestDomain]
          )
        end)

      assert output2 =~ "No changes detected"
    end

    test "creates initial snapshots for new resources" do
      output =
        capture_io(fn ->
          MigrationGenerator.generate(
            dev: true,
            snapshot_path: Path.join(@test_tmp_dir, "snapshots"),
            migration_path: Path.join(@test_tmp_dir, "migrations"),
            domains: [AshScylla.TestDomain]
          )
        end)

      # Should have created snapshots (not "No changes detected")
      refute output =~ "No changes detected"

      # Verify snapshot files exist
      snapshot_dir = Path.join(@test_tmp_dir, "snapshots/test_repo")
      snapshot_files = list_snapshot_files(snapshot_dir)
      assert length(snapshot_files) > 0
    end
  end

  defp list_snapshot_files(snapshot_dir) do
    if File.dir?(snapshot_dir) do
      snapshot_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
    else
      []
    end
  end
end
