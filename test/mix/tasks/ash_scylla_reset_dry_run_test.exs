defmodule Mix.Tasks.AshScylla.ResetDryRunTest do
  @moduledoc """
  Dry-run path tests for `mix ash_scylla.reset`: option handling, repo
  validation success, keyspace override, and default-repo discovery — all
  without touching a ScyllaDB instance.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defmodule ResetDryRunRepo do
    @moduledoc false

    def nodes, do: ["127.0.0.1:59999"]
    def keyspace, do: "reset_dry_run_ks"
  end

  describe "--dry-run" do
    test "prints the plan for an explicitly validated repo" do
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.AshScylla.Reset.run(["--repo", "Mix.Tasks.AshScylla.ResetDryRunTest.ResetDryRunRepo", "--dry-run"])
        end)

      assert output =~ "=== DRY RUN ==="
      assert output =~ "reset_dry_run_ks"
      assert output =~ "re-run migrations"
    end

    test "honors a --keyspace override" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Reset.run([
            "--repo",
            "Mix.Tasks.AshScylla.ResetDryRunTest.ResetDryRunRepo",
            "--keyspace",
            "override_ks",
            "--dry-run"
          ])
        end)

      assert output =~ "override_ks"
      refute output =~ "reset_dry_run_ks"
    end

    test "accepts --nodes without side effects in dry-run" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Reset.run([
            "--repo",
            "Mix.Tasks.AshScylla.ResetDryRunTest.ResetDryRunRepo",
            "--nodes",
            "127.0.0.1:59998",
            "--dry-run"
          ])
        end)

      assert output =~ "=== DRY RUN ==="
      # Dry-run never touches the network.
      refute output =~ "Dropping keyspace"
    end

    test "discovers a default repo when --repo is omitted" do
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.AshScylla.Reset.run(["--dry-run"])
        end)

      assert output =~ "=== DRY RUN ==="
    end

    test "rejects a repo missing nodes/0 even in dry-run" do
      defmodule MissingNodesRepo do
        def keyspace, do: "ks"
      end

      assert_raise Mix.Error, ~r/missing required functions: nodes\/0/, fn ->
        capture_io(fn ->
          Mix.Tasks.AshScylla.Reset.run([
            "--repo",
            "#{__MODULE__}.MissingNodesRepo",
            "--dry-run"
          ])
        end)
      end
    end
  end
end
