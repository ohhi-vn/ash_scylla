defmodule AshScylla.IntegrationTest do
  @moduledoc """
  Integration tests for AshScylla with a real ScyllaDB instance.

  To run these tests:
  1. Start ScyllaDB: podman run -p 9042:9042 docker.io/scylladb/scylla
  2. Wait for it to be ready (healthcheck)
  3. Run: mix test test/integration_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  describe "Basic CRUD operations with ScyllaDB" do
    @tag :skip
    test "connects to ScyllaDB" do
      # This test requires a running ScyllaDB instance
      # Configure the repo in config/test.exs
      assert true
    end
  end
end
