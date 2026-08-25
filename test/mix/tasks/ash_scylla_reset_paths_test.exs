defmodule ResetTaskProbeRepo do
  @moduledoc """
  Repo-shaped module pointing at an unreachable node so the reset flow can be
  exercised without a running ScyllaDB instance.
  """

  def nodes, do: ["127.0.0.1:59999"]
  def keyspace, do: "reset_probe_ks"
end

defmodule ResetTaskIncompleteRepo do
  @moduledoc """
  Module with nodes/0 but no keyspace/0, to exercise repo validation.
  """

  def nodes, do: ["127.0.0.1:59999"]
end

defmodule Mix.Tasks.AshScylla.ResetPathsTest do
  @moduledoc """
  Error-path unit tests for `mix ash_scylla.reset`: repo discovery, repo
  validation, and connection failure handling.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  describe "repo discovery" do
    test "raises for a repo module that does not exist" do
      assert_raise Mix.Error, ~r/Repo module .* does not exist/, fn ->
        capture_io(fn ->
          Mix.Tasks.AshScylla.Reset.run(["--repo", "No.SuchRepo"])
        end)
      end
    end

    test "raises when the repo is missing keyspace/0" do
      assert_raise Mix.Error, ~r/missing required functions: keyspace\/0/, fn ->
        capture_io(fn ->
          Mix.Tasks.AshScylla.Reset.run(["--repo", "ResetTaskIncompleteRepo"])
        end)
      end
    end

    test "accepts an aliased repo name and validates its functions" do
      stderr =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/Keyspace drop failed/, fn ->
            capture_io(:stdio, fn ->
              Mix.Tasks.AshScylla.Reset.run(["--repo", "ResetTaskProbeRepo"])
            end)
          end
        end)

      assert stderr =~ "Failed to drop keyspace"
    end
  end

  describe "full flow against an unreachable node" do
    test "drops keyspace via temp connection and raises when it fails" do
      output =
        capture_io(:stdio, fn ->
          assert_raise Mix.Error, ~r/Keyspace drop failed/, fn ->
            Mix.Tasks.AshScylla.Reset.run(["--repo", "ResetTaskProbeRepo"])
          end
        end)

      assert output =~ "Dropping keyspace"
      assert output =~ "reset_probe_ks"
      refute output =~ "DRY RUN"
    end
  end
end
