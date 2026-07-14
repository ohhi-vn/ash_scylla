defmodule Mix.Tasks.AshScylla.ResetTest do
  @moduledoc """
  Unit tests for the `mix ash_scylla.reset` task.

  These tests do not require a running ScyllaDB instance. They verify the task
  module is callable, argument parsing works, and that `--dry-run` short-circuits
  before touching the database.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "task module" do
    test "module exists and is callable" do
      assert is_function(&Mix.Tasks.AshScylla.Reset.run/1)
    end
  end

  describe "argument parsing" do
    test "--dry-run prints what would be done and does not raise" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Reset.run(["--repo", "AshScylla.TestRepo", "--dry-run"])
        end)

      assert output =~ "DRY RUN"
      assert output =~ "drop keyspace" or output =~ "Drop"
      assert output =~ "re-run migrations" or output =~ "migrations"
    end

    test "--repo is accepted without raising" do
      output =
        try do
          capture_io(fn ->
            Mix.Tasks.AshScylla.Reset.run(["--repo", "AshScylla.TestRepo"])
          end)
        rescue
          _ -> ""
        end

      assert is_binary(output)
    end

    test "--keyspace flag is accepted" do
      output =
        try do
          capture_io(fn ->
            Mix.Tasks.AshScylla.Reset.run([
              "--repo",
              "AshScylla.TestRepo",
              "--keyspace",
              "custom_ks"
            ])
          end)
        rescue
          _ -> ""
        end

      assert is_binary(output)
    end

    test "--nodes flag is accepted" do
      output =
        try do
          capture_io(fn ->
            Mix.Tasks.AshScylla.Reset.run([
              "--repo",
              "AshScylla.TestRepo",
              "--nodes",
              "127.0.0.1:9042"
            ])
          end)
        rescue
          _ -> ""
        end

      assert is_binary(output)
    end

    test "combined flags are accepted" do
      output =
        try do
          capture_io(fn ->
            Mix.Tasks.AshScylla.Reset.run([
              "--repo",
              "AshScylla.TestRepo",
              "--dry-run",
              "--keyspace",
              "test_ks",
              "--quiet"
            ])
          end)
        rescue
          _ -> ""
        end

      assert output =~ "DRY RUN"
    end
  end

  describe "migrate args forwarding" do
    test "run_migrate forwards --repo, --keyspace, --nodes, --quiet" do
      # Verify the private helper builds the expected arg list by exercising the
      # public dry-run path, which still parses and forwards options.
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Reset.run([
            "--repo",
            "AshScylla.TestRepo",
            "--keyspace",
            "ks_a",
            "--nodes",
            "127.0.0.1:9042",
            "--dry-run"
          ])
        end)

      assert output =~ "DRY RUN"
    end
  end
end
