defmodule AshScylla.ReleaseTest do
  use ExUnit.Case, async: true

  alias AshScylla.Release

  describe "find_resources/2" do
    test "returns custom resources when provided in opts" do
      assert Release.find_resources([], resources: [AshScylla.TestResource]) == [
               AshScylla.TestResource
             ]
    end

    test "returns empty list when no resources provided and no loaded apps" do
      result = Release.find_resources([], [])
      assert is_list(result)
    end

    test "returns empty list for empty resources list" do
      assert Release.find_resources([], resources: []) == []
    end
  end

  describe "rollback/3" do
    test "returns :ok (placeholder)" do
      assert Release.rollback(AshScylla.TestRepo, 20_240_101_000_000, [AshScylla.TestRepo]) == :ok
    end

    test "accepts string version" do
      assert Release.rollback(AshScylla.TestRepo, "20240101000000", [AshScylla.TestRepo]) == :ok
    end
  end

  describe "create_keyspace/2" do
    defmodule MockRepo do
      def create_keyspace(_name, _opts), do: {:ok, %{}}
    end

    defmodule MockFailingRepo do
      def create_keyspace(_name, _opts), do: {:error, :mock_failure}
    end

    test "returns :ok on success" do
      assert Release.create_keyspace(MockRepo, []) == :ok
    end

    test "returns {:error, reason} on failure" do
      assert Release.create_keyspace(MockFailingRepo, []) == {:error, :mock_failure}
    end

    test "passes opts to repo.create_keyspace" do
      defmodule MockOptsRepo do
        def create_keyspace(_name, opts), do: {:ok, opts}
      end

      assert Release.create_keyspace(MockOptsRepo, strategy: :simple) == :ok
    end
  end
end
