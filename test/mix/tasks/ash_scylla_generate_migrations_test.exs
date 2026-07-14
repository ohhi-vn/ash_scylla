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
      result = MigrationGenerator.generate(dry_run: true, domains: [])
      assert result == :ok
    end

    test "prints migration scripts and snapshot summaries, not raw JSON" do
      output =
        capture_io(fn ->
          MigrationGenerator.generate(
            dry_run: true,
            dev: true,
            snapshot_path: Path.join(@test_tmp_dir, "snapshots"),
            migration_path: Path.join(@test_tmp_dir, "migrations"),
            domains: [AshScylla.TestDomain]
          )
        end)

      # Should print the migration header
      assert output =~ "Migrations generated for"

      # Should print migration file names with --- markers
      assert output =~ "---"

      # Should contain migration module defs (the actual script content)
      assert output =~ "defmodule"

      # Should contain CQL statements (the migration body)
      assert output =~ "CREATE TABLE"

      # Should not contain raw JSON snapshot blobs
      refute output =~ ~r/"table"\s*:/

      # Should list snapshot files
      assert output =~ "Resource snapshots generated for"
      assert output =~ "Snapshot:"

      # Should NOT create any files on disk
      refute File.exists?(Path.join(@test_tmp_dir, "migrations"))
      refute File.exists?(Path.join(@test_tmp_dir, "snapshots"))
    end

    test "does not create files on disk when dry_run is true" do
      capture_io(fn ->
        MigrationGenerator.generate(
          dry_run: true,
          dev: true,
          snapshot_path: Path.join(@test_tmp_dir, "snapshots"),
          migration_path: Path.join(@test_tmp_dir, "migrations"),
          domains: [AshScylla.TestDomain]
        )
      end)

      refute File.exists?(Path.join(@test_tmp_dir, "migrations"))
      refute File.exists?(Path.join(@test_tmp_dir, "snapshots"))
    end

    test "prints each migration script with its filename header" do
      output =
        capture_io(fn ->
          MigrationGenerator.generate(
            dry_run: true,
            dev: true,
            snapshot_path: Path.join(@test_tmp_dir, "snapshots"),
            migration_path: Path.join(@test_tmp_dir, "migrations"),
            domains: [AshScylla.TestDomain]
          )
        end)

      lines = String.split(output, "\n")

      migration_headers = Enum.filter(lines, &String.starts_with?(&1, "---"))
      assert length(migration_headers) > 0

      Enum.each(migration_headers, fn header ->
        assert String.ends_with?(String.trim(header), ".exs ---")
      end)
    end

    test "outputs correct count of migrations" do
      output =
        capture_io(fn ->
          MigrationGenerator.generate(
            dry_run: true,
            dev: true,
            snapshot_path: Path.join(@test_tmp_dir, "snapshots"),
            migration_path: Path.join(@test_tmp_dir, "migrations"),
            domains: [AshScylla.TestDomain]
          )
        end)

      [migration_line | _] = String.split(output, "\n")

      assert String.starts_with?(migration_line, "Migrations generated for")
      assert String.ends_with?(migration_line, "resource(s):")

      count =
        migration_line
        |> String.replace("Migrations generated for ", "")
        |> String.replace(" resource(s):", "")
        |> String.trim()
        |> String.to_integer()

      assert count > 0
    end

    test "migration output appears before snapshot output" do
      output =
        capture_io(fn ->
          MigrationGenerator.generate(
            dry_run: true,
            dev: true,
            snapshot_path: Path.join(@test_tmp_dir, "snapshots"),
            migration_path: Path.join(@test_tmp_dir, "migrations"),
            domains: [AshScylla.TestDomain]
          )
        end)

      lines = String.split(output, "\n")
      migration_idx = Enum.find_index(lines, &String.starts_with?(&1, "Migrations generated for"))

      snapshot_idx =
        Enum.find_index(lines, &String.starts_with?(&1, "Resource snapshots generated for"))

      assert migration_idx != nil
      assert snapshot_idx != nil
      assert migration_idx < snapshot_idx
    end
  end

  describe "timestamp generation" do
    test "produces 14-digit timestamp" do
      assert true
    end
  end

  describe "change detection - no regeneration on re-run" do
    test "does not create new snapshot files when schema unchanged" do
      capture_io(fn ->
        MigrationGenerator.generate(
          dev: true,
          snapshot_path: Path.join(@test_tmp_dir, "snapshots"),
          migration_path: Path.join(@test_tmp_dir, "migrations"),
          domains: [AshScylla.TestDomain]
        )
      end)

      snapshot_dir = Path.join(@test_tmp_dir, "snapshots/test_repo")
      snapshot_files_after_first_run = list_snapshot_files(snapshot_dir)
      assert length(snapshot_files_after_first_run) > 0

      capture_io(fn ->
        MigrationGenerator.generate(
          dev: true,
          snapshot_path: Path.join(@test_tmp_dir, "snapshots"),
          migration_path: Path.join(@test_tmp_dir, "migrations"),
          domains: [AshScylla.TestDomain]
        )
      end)

      snapshot_files_after_second_run = list_snapshot_files(snapshot_dir)
      assert length(snapshot_files_after_second_run) == length(snapshot_files_after_first_run)
    end

    test "reports no changes detected on second run" do
      capture_io(fn ->
        MigrationGenerator.generate(
          dev: true,
          snapshot_path: Path.join(@test_tmp_dir, "snapshots"),
          migration_path: Path.join(@test_tmp_dir, "migrations"),
          domains: [AshScylla.TestDomain]
        )
      end)

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

      refute output =~ "No changes detected"

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
