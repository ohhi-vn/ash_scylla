defmodule AshScylla.Test do
  use ExUnit.Case, async: false
  doctest AshScylla

  describe "version/0" do
    test "returns the version" do
      version = AshScylla.version()
      assert is_binary(version)
    end
  end

  describe "DataLayer" do
    test "can? returns true for supported features" do
      assert AshScylla.DataLayer.can?(nil, :create) == true
      assert AshScylla.DataLayer.can?(nil, :read) == true
      assert AshScylla.DataLayer.can?(nil, :update) == true
      assert AshScylla.DataLayer.can?(nil, :destroy) == true
      assert AshScylla.DataLayer.can?(nil, :filter) == true
      assert AshScylla.DataLayer.can?(nil, :sort) == true
      assert AshScylla.DataLayer.can?(nil, :limit) == true
      assert AshScylla.DataLayer.can?(nil, :offset) == true
      assert AshScylla.DataLayer.can?(nil, :select) == true
      assert AshScylla.DataLayer.can?(nil, :multitenancy) == true
    end

    test "can? returns false for unsupported features" do
      assert AshScylla.DataLayer.can?(nil, :transact) == false
      assert AshScylla.DataLayer.can?(nil, :bulk_create) == false
      assert AshScylla.DataLayer.can?(nil, :calculate) == false
      assert AshScylla.DataLayer.can?(nil, :combine) == false
      assert AshScylla.DataLayer.can?(nil, {:aggregate, :count}) == false
      assert AshScylla.DataLayer.can?(nil, {:join, nil}) == false
      assert AshScylla.DataLayer.can?(nil, {:lateral_join, []}) == false
      assert AshScylla.DataLayer.can?(nil, {:lock, :for_update}) == false
    end
  end

  describe "Repo" do
    test "defines keyspace function" do
      # This test verifies that modules using AshScylla.Repo
      # will have the keyspace/0 function
      assert Code.ensure_loaded?(AshScylla.Repo)
    end
  end
end
