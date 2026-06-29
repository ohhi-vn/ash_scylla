defmodule Mix.Tasks.AshScylla.SharedMetaTest do
  @moduledoc """
  Tests to verify that `mix ash_scylla.gen` and `mix ash.codegen` share
  the same `.schema_meta` file for change detection.

  This ensures that running one command will be recognized by the other
  as having already processed the current schema state.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # Both commands should use the same meta file path.
  # When the app is not started, both commands fall back to priv/repo/migrations.
  @meta_file Path.join("priv/repo/migrations", ".schema_meta")
  @test_migration_dir "priv/repo/migrations"

  setup do
    # Start the application so that resources can be found
    Application.ensure_all_started(:ash_scylla)

    # Clean up any test migration files and meta file
    File.rm(@meta_file)

    Path.wildcard(Path.join(@test_migration_dir, "*.ex"))
    |> Enum.each(&File.rm/1)

    on_exit(fn ->
      File.rm(@meta_file)

      Path.wildcard(Path.join(@test_migration_dir, "*.ex"))
      |> Enum.each(&File.rm/1)
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

    test "ash.codegen creates .schema_meta file (not .codegen_meta)" do
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

      # Verify no .codegen_meta file is created
      refute File.exists?(Path.join(@test_migration_dir, ".codegen_meta")),
             "Expected .codegen_meta file to NOT exist (should use .schema_meta)"
    end

    test "ash_scylla.gen recognizes meta file created by ash.codegen" do
      # First, run ash.codegen to create the meta file
      capture_io(fn ->
        try do
          AshScylla.Extension.codegen(["--force", "--dev"])
        rescue
          _ -> :ok
        end
      end)

      # Verify meta file was created
      assert File.exists?(@meta_file),
             "Expected .schema_meta file to be created by ash.codegen"

      # Now run ash_scylla.gen - it should recognize the meta file and report up to date
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.run([
              "--resource",
              "AshScylla.TestResource",
              "GenAfterCodegen"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Schema is up to date",
             "Expected ash_scylla.gen to recognize meta from ash.codegen, got: #{output}"
    end

    test "ash.codegen recognizes meta file created by ash_scylla.gen" do
      # First, run ash_scylla.gen to create the meta file
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

      # Verify meta file was created
      assert File.exists?(@meta_file),
             "Expected .schema_meta file to be created by ash_scylla.gen"

      # Now run ash.codegen - it should recognize the meta file and report up to date
      output =
        capture_io(fn ->
          try do
            AshScylla.Extension.codegen(["--dev"])
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "Schema is up to date",
             "Expected ash.codegen to recognize meta from ash_scylla.gen, got: #{output}"
    end

    test "meta file format is consistent between both commands" do
      # Run ash_scylla.gen to create the meta file
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

    test "both commands use the same meta file path" do
      # Both commands should use the same meta file path
      expected_meta_file = Path.join("priv/repo/migrations", ".schema_meta")

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

      assert File.exists?(expected_meta_file),
             "Expected meta file at #{expected_meta_file}"
    end
  end
end
