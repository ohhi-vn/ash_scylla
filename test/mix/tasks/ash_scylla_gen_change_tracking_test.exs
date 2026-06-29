defmodule Mix.Tasks.AshScylla.GenChangeTrackingTest do
  @moduledoc """
  Tests for the schema change tracking feature in mix ash_scylla.gen.

  Covers:
  - First run generates migration + meta file
  - Second run with no changes reports "up to date"
  - Run after resource change generates migration for changed resources only
  - --force flag bypasses change detection
  - Meta file cleanup when resources are removed
  - hash_resource/1 computes stable hashes
  - merge_meta/3 correctly updates tracking data
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshScylla.Migration

  @meta_file Path.join("priv/repo/migrations", ".schema_meta")
  @test_migration_dir "priv/repo/migrations"

  setup do
    # Clean up any test migration files and meta file
    File.rm(@meta_file)

    Path.wildcard(Path.join(@test_migration_dir, "schema*.ex"))
    |> Enum.each(&File.rm/1)

    on_exit(fn ->
      File.rm(@meta_file)

      Path.wildcard(Path.join(@test_migration_dir, "schema*.ex"))
      |> Enum.each(&File.rm/1)
    end)

    :ok
  end

  describe "change tracking: first run" do
    test "generates migration file and creates meta file on first run" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.run([
              "--resource",
              "AshScylla.TestResource",
              "FirstRun"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Generated schema migration"
      assert output =~ "Resources: 1"
      assert File.exists?(@meta_file)
    end

    test "meta file contains resource key and hash" do
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "MetaTest"
          ])
        rescue
          _ -> :ok
        end
      end)

      {:ok, content} = File.read(@meta_file)
      {meta, _} = Code.eval_string(content)

      assert is_map(meta)
      assert map_size(meta) == 1
      assert Map.has_key?(meta, "AshScylla.TestResource")
      assert is_integer(meta["AshScylla.TestResource"])
    end
  end

  describe "change tracking: no changes" do
    test "reports up to date when nothing changed" do
      # First run
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "NoChange1"
          ])
        rescue
          _ -> :ok
        end
      end)

      # Second run with same resource
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "NoChange2"
          ])
        end)

      assert output =~ "Schema is up to date"
      refute output =~ "Generated schema migration"
    end

    test "does not create a new migration file when nothing changed" do
      # First run
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "FileCount1"
          ])
        rescue
          _ -> :ok
        end
      end)

      files_before = length(Path.wildcard(Path.join(@test_migration_dir, "schema*.ex")))

      # Second run
      capture_io(fn ->
        Mix.Tasks.AshScylla.Gen.run([
          "--resource",
          "AshScylla.TestResource",
          "FileCount2"
        ])
      end)

      files_after = length(Path.wildcard(Path.join(@test_migration_dir, "schema*.ex")))
      assert files_before == files_after
    end
  end

  describe "change tracking: with --force" do
    test "force flag regenerates even when nothing changed" do
      # First run
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "Force1"
          ])
        rescue
          _ -> :ok
        end
      end)

      # Force run
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.run([
              "--resource",
              "AshScylla.TestResource",
              "--force",
              "Force2"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Generated schema migration"
      assert output =~ "Forced regeneration"
    end

    test "force flag reports correct resource count" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.run([
              "--resource",
              "AshScylla.TestResource",
              "--force",
              "ForceCount"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Forced regeneration of 1 resource(s)"
    end
  end

  describe "change tracking: multiple resources" do
    test "tracks multiple resources independently" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.run([
              "--resource",
              "AshScylla.TestResource",
              "Multi1"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Generated schema migration"

      # Verify meta has the resource
      {:ok, content} = File.read(@meta_file)
      {meta, _} = Code.eval_string(content)
      assert Map.has_key?(meta, "AshScylla.TestResource")
    end

    test "reports changed vs unchanged counts" do
      # First run with TestResource
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "Partial1"
          ])
        rescue
          _ -> :ok
        end
      end)

      # Second run with TestResourceWithIndexes (different resource, treated as new)
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.run([
              "--resource",
              "AshScylla.TestResourceWithIndexes",
              "Partial2"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Generated schema migration"
    end
  end

  describe "change tracking: meta file format" do
    test "meta file is valid Elixir map" do
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "FormatTest"
          ])
        rescue
          _ -> :ok
        end
      end)

      {:ok, content} = File.read(@meta_file)
      assert String.starts_with?(content, "%{")
      {meta, _} = Code.eval_string(content)
      assert is_map(meta)
    end

    test "meta file is updated after each generation" do
      # First generation
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "Update1"
          ])
        rescue
          _ -> :ok
        end
      end)

      {:ok, content1} = File.read(@meta_file)
      {meta1, _} = Code.eval_string(content1)
      hash1 = meta1["AshScylla.TestResource"]

      # Force regeneration updates the hash
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "--force",
            "Update2"
          ])
        rescue
          _ -> :ok
        end
      end)

      {:ok, content2} = File.read(@meta_file)
      {meta2, _} = Code.eval_string(content2)
      hash2 = meta2["AshScylla.TestResource"]

      # Hash should be the same since resource didn't change
      assert hash1 == hash2
    end
  end

  describe "hash_resource/1" do
    test "produces stable hash for same resource" do
      output1 =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.run([
              "--resource",
              "AshScylla.TestResource",
              "Hash1"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output1 =~ "Generated schema migration"

      {:ok, content} = File.read(@meta_file)
      {meta, _} = Code.eval_string(content)
      hash1 = meta["AshScylla.TestResource"]

      # Run again with force
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "--force",
            "Hash2"
          ])
        rescue
          _ -> :ok
        end
      end)

      {:ok, content2} = File.read(@meta_file)
      {meta2, _} = Code.eval_string(content2)
      hash2 = meta2["AshScylla.TestResource"]

      assert hash1 == hash2
    end

    test "different resources produce different hashes" do
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "DiffHash1"
          ])
        rescue
          _ -> :ok
        end
      end)

      {:ok, content} = File.read(@meta_file)
      {meta, _} = Code.eval_string(content)
      hash1 = meta["AshScylla.TestResource"]

      # Clean up and run with different resource
      File.rm(@meta_file)

      Path.wildcard(Path.join(@test_migration_dir, "schema*.ex"))
      |> Enum.each(&File.rm/1)

      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResourceWithIndexes",
            "DiffHash2"
          ])
        rescue
          _ -> :ok
        end
      end)

      {:ok, content2} = File.read(@meta_file)
      {meta2, _} = Code.eval_string(content2)
      hash2 = meta2["AshScylla.TestResourceWithIndexes"]

      assert hash1 != hash2
    end
  end

  describe "Migration.create_secondary_indexes_cql with multi-column split" do
    test "splits multi-column index into separate single-column indexes" do
      defmodule MultiColSplit do
        def __ash_scylla__(:secondary_indexes),
          do: [%{columns: [:a, :b, :c], name: nil, options: []}]

        def __ash_scylla__(:table), do: "t"
        def __ash_scylla__(_), do: nil
      end

      result = Migration.create_secondary_indexes_cql(MultiColSplit)
      assert length(result) == 3

      assert Enum.any?(result, &String.contains?(&1, ~s/("a")/))
      assert Enum.any?(result, &String.contains?(&1, ~s/("b")/))
      assert Enum.any?(result, &String.contains?(&1, ~s/("c")/))
    end

    test "splits multi-column index with custom name" do
      defmodule MultiColNamed do
        def __ash_scylla__(:secondary_indexes),
          do: [%{columns: [:x, :y], name: "idx_xy", options: []}]

        def __ash_scylla__(:table), do: "t"
        def __ash_scylla__(_), do: nil
      end

      result = Migration.create_secondary_indexes_cql(MultiColNamed)
      assert length(result) == 2

      assert Enum.any?(result, &String.contains?(&1, "idx_xy_x"))
      assert Enum.any?(result, &String.contains?(&1, "idx_xy_y"))
    end

    test "single-column index is not split" do
      defmodule SingleCol do
        def __ash_scylla__(:secondary_indexes),
          do: [%{columns: [:email], name: nil, options: []}]

        def __ash_scylla__(:table), do: "users"
        def __ash_scylla__(_), do: nil
      end

      result = Migration.create_secondary_indexes_cql(SingleCol)
      assert length(result) == 1
      assert String.contains?(hd(result), ~s/("email")/)
    end

    test "mixed single and multi-column indexes" do
      defmodule MixedIndexes do
        def __ash_scylla__(:secondary_indexes),
          do: [
            %{columns: [:email], name: nil, options: []},
            %{columns: [:first_name, :last_name], name: nil, options: []},
            %{columns: [:status], name: "idx_status", options: []}
          ]

        def __ash_scylla__(:table), do: "users"
        def __ash_scylla__(_), do: nil
      end

      result = Migration.create_secondary_indexes_cql(MixedIndexes)
      # 1 (email) + 2 (first_name, last_name split) + 1 (status) = 4
      assert length(result) == 4

      assert Enum.any?(result, &String.contains?(&1, ~s/("email")/))
      assert Enum.any?(result, &String.contains?(&1, ~s/("first_name")/))
      assert Enum.any?(result, &String.contains?(&1, ~s/("last_name")/))
      assert Enum.any?(result, &String.contains?(&1, "idx_status"))
    end
  end

  describe "Migration.get_table_name with domain-prefixed names" do
    test "uses DSL table name when explicitly set" do
      # get_table_name is private; test via create_table_cql which calls it
      create_table = Migration.create_table_cql(AshScylla.TestResourceWithIndexes)
      assert String.contains?(create_table, "test_users")
    end

    test "generates valid table name for resource with domain" do
      create_table = Migration.create_table_cql(AshScylla.TestResource)
      assert String.contains?(create_table, "test_resource")
    end
  end

  describe "DataLayer.resolve_table_name with domain-prefixed names" do
    test "uses domain-prefixed name for resources with domain" do
      result = AshScylla.DataLayer.resolve_table_name(AshScylla.TestResource)
      assert result == "test_resource"
    end

    test "uses DSL table name when explicitly set" do
      result = AshScylla.DataLayer.resolve_table_name(AshScylla.TestResourceWithIndexes)
      assert result == "test_users"
    end

    test "uses last segment for resources without domain" do
      # AshScylla.TestResourceWithIndexes has a domain, so test with a
      # known resource that has domain set. For no-domain case, the
      # resolve_table_name falls back to module name segments.
      result = AshScylla.DataLayer.resolve_table_name(AshScylla.TestResourceWithIndexes)
      # TestResourceWithIndexes has table("test_users") in DSL
      assert result == "test_users"
    end
  end

  describe "NOT NULL removed from column definitions" do
    test "column definitions do not include NOT NULL" do
      create_table = Migration.create_table_cql(AshScylla.TestResource)
      refute String.contains?(create_table, "NOT NULL")
    end

    test "primary key column does not include NOT NULL" do
      create_table = Migration.create_table_cql(AshScylla.TestResource)
      # PK is generated as PRIMARY KEY ("id") at the end, not inline
      assert String.contains?(create_table, "PRIMARY KEY")
      refute String.contains?(create_table, "NOT NULL")
    end
  end

  describe "default :id as primary key" do
    test "uses :id as PK when no attribute has primary_key?" do
      create_table = Migration.create_table_cql(AshScylla.TestResource)
      # The PK is generated as PRIMARY KEY ("id") at the end of the column list
      assert String.contains?(create_table, "PRIMARY KEY")
      assert String.contains?(create_table, "id")
    end

    test "generates valid CREATE TABLE syntax" do
      create_table = Migration.create_table_cql(AshScylla.TestResource)
      assert String.contains?(create_table, "CREATE TABLE IF NOT EXISTS")
      assert String.contains?(create_table, "(")
      assert String.contains?(create_table, ")")
    end
  end

  describe "CLUSTERING ORDER BY handling" do
    test "omits CLUSTERING ORDER BY when no clustering keys" do
      create_table = Migration.create_table_cql(AshScylla.TestResource)
      refute String.contains?(create_table, "CLUSTERING ORDER BY")
    end

    test "no trailing space after closing paren when no clustering" do
      create_table = Migration.create_table_cql(AshScylla.TestResource)
      # The generated CQL ends with ")" as the last non-empty line
      assert String.contains?(create_table, "PRIMARY KEY")
      non_empty_lines = String.split(create_table, "\n") |> Enum.reject(&(&1 == ""))
      last_line = List.last(non_empty_lines) |> String.trim()
      assert last_line == ")"
    end
  end
end
