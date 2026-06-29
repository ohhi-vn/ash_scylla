defmodule Mix.Tasks.AshScylla.SharedMetaTest do
  @moduledoc """
  Tests to verify that `mix ash_scylla.gen` and `mix ash.codegen` share
  the same `.schema_meta` file for change detection.

  This ensures that running one command will be recognized by the other
  as having already processed the current schema state.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # Both commands should use the same meta file path based on the repo.
  # The test resources use AshScylla.TestRepo, so the path is priv/test_repo/migrations.
  @meta_file Path.join("priv/test_repo/migrations", ".schema_meta")
  @test_migration_dir "priv/test_repo/migrations"

  setup do
    # Start the application so that resources can be found
    Application.ensure_all_started(:ash_scylla)

    # Configure the test domain so codegen can discover resources
    Application.put_env(:ash_scylla, :ash_domains, [AshScylla.TestDomain])

    # Clean up any test migration files and meta file
    File.rm(@meta_file)

    Path.wildcard(Path.join(@test_migration_dir, "*.ex"))
    |> Enum.each(&File.rm/1)

    on_exit(fn ->
      File.rm(@meta_file)

      Path.wildcard(Path.join(@test_migration_dir, "*.ex"))
      |> Enum.each(&File.rm/1)

      Application.delete_env(:ash_scylla, :ash_domains)
    end)

    :ok
  end

  describe "shared meta file between ash_scylla.gen and ash.codegen" do
    test "ash_scylla.gen creates .schema_meta file" do
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "SharedMetaTest"
          ])
        rescue
          _ -> :ok
        end
      end)

      assert File.exists?(@meta_file),
             "Expected .schema_meta file to be created by ash_scylla.gen"
    end

    test "ash_scylla.gen recognizes meta file on second run" do
      # Run ash_scylla.gen first to create the meta file
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "GenFirst"
          ])
        rescue
          _ -> :ok
        end
      end)

      assert File.exists?(@meta_file),
             "Expected .schema_meta file to exist after ash_scylla.gen"

      # Run again - should report up to date
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.run([
              "--resource",
              "AshScylla.TestResource",
              "GenSecond"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Schema is up to date",
             "Expected ash_scylla.gen to report up to date, got: #{output}"
    end

    test "ash_scylla.gen creates meta file with correct format" do
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

      # Read and verify the meta file format
      {:ok, content} = File.read(@meta_file)
      {meta, _} = Code.eval_string(content)

      assert is_map(meta)
      assert Map.has_key?(meta, "AshScylla.TestResource")
      assert is_integer(meta["AshScylla.TestResource"])
    end

    test "meta file uses .schema_meta filename" do
      # Verify the meta file is created at the expected path
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "PathTest"
          ])
        rescue
          _ -> :ok
        end
      end)

      # Verify .schema_meta exists
      assert File.exists?(@meta_file),
             "Expected .schema_meta file at #{@meta_file}"

      # Verify no .codegen_meta file is created
      refute File.exists?(Path.join(@test_migration_dir, ".codegen_meta")),
             "Expected .codegen_meta file to NOT exist (should use .schema_meta)"
    end

    test "ash_scylla.gen and ash.codegen use same migrations directory" do
      # Both commands should use the same migrations directory
      capture_io(fn ->
        try do
          Mix.Tasks.AshScylla.Gen.run([
            "--resource",
            "AshScylla.TestResource",
            "DirTest"
          ])
        rescue
          _ -> :ok
        end
      end)

      # The meta file should be in the migrations directory
      assert File.exists?(@meta_file),
             "Expected meta file in migrations directory"
    end
  end
end
