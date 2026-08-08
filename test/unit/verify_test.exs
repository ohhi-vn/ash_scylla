defmodule AshScyllaVerifyTest do
  use ExUnit.Case, async: true

  describe "verify/2 with check_connection?: false" do
    test "returns {:ok, report} without connecting to Scylla" do
      assert {:ok, report} = AshScylla.verify(AshScylla.TestRepo, check_connection?: false)
      assert report.repo == AshScylla.TestRepo
      assert report.connection.checked? == false
      assert report.keyspace_report.checked? == false
    end

    test "includes nodes and keyspace in report" do
      assert {:ok, report} = AshScylla.verify(AshScylla.TestRepo, check_connection?: false)
      assert is_list(report.nodes)
      assert report.nodes != []
      assert is_binary(report.keyspace)
    end

    test "resources report is empty when no resources specified" do
      assert {:ok, report} = AshScylla.verify(AshScylla.TestRepo, check_connection?: false)
      assert report.resources == []
    end

    test "reports resource info when resources are specified" do
      assert {:ok, report} =
               AshScylla.verify(AshScylla.TestRepo,
                 check_connection?: false,
                 resources: [AshScylla.TestResource]
               )

      assert report.resources != []
      assert hd(report.resources).checked? == false
    end
  end

  describe "version/0" do
    test "returns a valid version string" do
      version = AshScylla.version()
      assert is_binary(version)
      assert String.match?(version, ~r/^\d+\.\d+\.\d+/)
    end
  end
end
