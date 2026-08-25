defmodule SetupTaskSnakeCaseRepo do
  @moduledoc """
  Top-level fake repo so the task's underscore-to-alias conversion resolves it.
  """

  def create_keyspace(_name \\ nil, _opts \\ []), do: {:ok, :created}
end

defmodule Mix.Tasks.AshScylla.SetupTaskTest do
  @moduledoc """
  Unit tests for `mix ash_scylla.setup`.

  Uses fake repo modules so no database connection is attempted.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defmodule FakeRepo do
    @behaviour AshScylla.Repo

    def create_keyspace(_name \\ nil, _opts \\ []), do: {:ok, :created}

    def config, do: []
    def keyspace, do: nil
    def nodes, do: []
    def connection, do: nil
    def query(_cql, _params, _opts \\ []), do: {:error, :not_connected}
    def query!(_cql, _params, _opts \\ []), do: raise("offline")
    def query_all(_cql, _params, _opts \\ []), do: {:error, :not_connected}
    def prepare(_cql, _opts \\ []), do: {:error, :not_connected}
    def prepare!(_cql, _opts \\ []), do: raise("offline")
    def drop_keyspace(_name \\ nil), do: {:ok, :dropped}
    def child_spec(_opts), do: %{id: __MODULE__}
    def disable_lwt?, do: false
    def disable_atomic_actions?, do: false
    def installed_extensions, do: []

    def build_replication_clause(_opts), do: "{'class': 'NetworkTopologyStrategy'}"
  end

  defmodule FailingRepo do
    @behaviour AshScylla.Repo

    def create_keyspace(_name \\ nil, _opts \\ []), do: {:error, :cluster_unreachable}

    def config, do: []
    def keyspace, do: nil
    def nodes, do: []
    def connection, do: nil
    def query(_cql, _params, _opts \\ []), do: {:error, :not_connected}
    def query!(_cql, _params, _opts \\ []), do: raise("offline")
    def query_all(_cql, _params, _opts \\ []), do: {:error, :not_connected}
    def prepare(_cql, _opts \\ []), do: {:error, :not_connected}
    def prepare!(_cql, _opts \\ []), do: raise("offline")
    def drop_keyspace(_name \\ nil), do: {:ok, :dropped}
    def child_spec(_opts), do: %{id: __MODULE__}
    def disable_lwt?, do: false
    def disable_atomic_actions?, do: false
    def installed_extensions, do: []

    def build_replication_clause(_opts), do: "{'class': 'NetworkTopologyStrategy'}"
  end

  describe "run/1 with --repo" do
    test "creates the keyspace on the given repo" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Setup.run(["--repo", "Mix.Tasks.AshScylla.SetupTaskTest.FakeRepo"])
        end)

      assert output =~ "Creating keyspace for"
      assert output =~ "FakeRepo"
      assert output =~ "Keyspace created successfully."
    end

    test "raises when keyspace creation fails" do
      output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/Keyspace creation failed/, fn ->
            Mix.Tasks.AshScylla.Setup.run([
              "--repo",
              "Mix.Tasks.AshScylla.SetupTaskTest.FailingRepo"
            ])
          end
        end)

      assert output =~ "Failed to create keyspace"
      assert output =~ ":cluster_unreachable"
    end
  end

  describe "default repo discovery" do
    test "raises when no repo module exists in the project" do
      assert_raise Mix.Error, ~r/No repo found/, fn ->
        capture_io(fn ->
          Mix.Tasks.AshScylla.Setup.run([])
        end)
      end
    end
  end

  describe "repo name conversion" do
    test "converts underscored repo names to module aliases" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Setup.run(["--repo", "setup_task_snake_case_repo"])
        end)

      assert output =~ "Creating keyspace for"
      assert output =~ "SnakeCaseRepo"
      assert output =~ "Keyspace created successfully."
    end

    test "converts nested underscored repo names to nested aliases" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshScylla.Setup.run([
            "--repo",
            "mix/tasks/ash_scylla/setup_task_test/fake_repo"
          ])
        end)

      assert output =~ "FakeRepo"
      assert output =~ "Keyspace created successfully."
    end
  end
end
