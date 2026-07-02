defmodule AshScylla.Connection.DispatchTest do
  @moduledoc """
  Unit tests for AshScylla.Connection module dispatch helpers.

  These tests verify that the module dispatch functions correctly route
  between Xandra and Xandra.Cluster based on the cluster? flag.
  They do not require a running ScyllaDB instance.
  """
  use ExUnit.Case, async: true

  alias AshScylla.Connection

  describe "execute_module/1" do
    test "returns Xandra.Cluster for true" do
      assert Connection.execute_module(true) == Xandra.Cluster
    end

    test "returns Xandra for false" do
      assert Connection.execute_module(false) == Xandra
    end

    test "returns Xandra for nil" do
      assert Connection.execute_module(nil) == Xandra
    end
  end

  describe "prepare_module/1" do
    test "returns Xandra.Cluster for true" do
      assert Connection.prepare_module(true) == Xandra.Cluster
    end

    test "returns Xandra for false" do
      assert Connection.prepare_module(false) == Xandra
    end
  end

  describe "stop_module/1" do
    test "returns Xandra.Cluster for true" do
      assert Connection.stop_module(true) == Xandra.Cluster
    end

    test "returns Xandra for false" do
      assert Connection.stop_module(false) == Xandra
    end
  end

  describe "query module dispatch" do
    test "query/4 dispatches to Xandra.Cluster when cluster? is true" do
      assert Xandra.Cluster == Connection.execute_module(true)
    end

    test "query/4 dispatches to Xandra when cluster? is false" do
      assert Xandra == Connection.execute_module(false)
    end

    test "prepare/3 dispatches to Xandra.Cluster when cluster? is true" do
      assert Xandra.Cluster == Connection.prepare_module(true)
    end

    test "prepare/3 dispatches to Xandra when cluster? is false" do
      assert Xandra == Connection.prepare_module(false)
    end

    test "stop/1 dispatches to Xandra.Cluster when cluster? is true" do
      assert Xandra.Cluster == Connection.stop_module(true)
    end

    test "stop/1 dispatches to Xandra when cluster? is false" do
      assert Xandra == Connection.stop_module(false)
    end
  end
end
