defmodule AshScylla.VerifyOfflineTest do
  @moduledoc """
  Covers the connection-checked branches of `AshScylla.verify/2` that fail
  fast against an unreachable node, without requiring a live ScyllaDB.
  """

  use ExUnit.Case, async: true

  alias AshScylla.TestRepo
  alias AshScylla.TestResource

  @dead_node "127.0.0.1:59999"

  test "verify reports a connection failure when the cluster is unreachable" do
    assert {:error, {:connection_failed, %Xandra.ConnectionError{}}} =
             AshScylla.verify(TestRepo,
               nodes: [@dead_node],
               connect_timeout: 500,
               resources: [TestResource]
             )
  end
end
