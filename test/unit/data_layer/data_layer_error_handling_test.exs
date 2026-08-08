defmodule AshScylla.DataLayerErrorHandlingTest do
  @moduledoc """
  Tests for DataLayer error handling improvements.

  Verifies that:
  - update_query, destroy_query, run_aggregate_query route errors through handle_result
  - No raw Xandra errors leak to callers
  - Unknown filter error is centralized
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer
  alias AshScylla.Error
  alias AshScylla.Error.ScyllaError
  alias AshScylla.Query

  # Mock repos that return controlled errors
  defmodule MockErrorRepo do
    @moduledoc false
    def query(_query, _params, _opts),
      do: {:error, %Xandra.Error{reason: :overloaded, message: nil, warnings: []}}
  end

  defmodule MockTimeoutRepo do
    @moduledoc false
    def query(_query, _params, _opts),
      do: {:error, %Xandra.Error{reason: :write_timeout, message: nil, warnings: []}}
  end

  defmodule MockReadTimeoutRepo do
    @moduledoc false
    def query(_query, _params, _opts),
      do: {:error, %Xandra.Error{reason: :read_timeout, message: nil, warnings: []}}
  end

  # Test resources with mock repos
  defmodule TestResourceForError do
    use Ash.Resource,
      domain: AshScylla.TestDomain,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(MockErrorRepo)
      table("test_resource")
      keyspace("ash_scylla_test")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule TestResourceForTimeout do
    use Ash.Resource,
      domain: AshScylla.TestDomain,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(MockTimeoutRepo)
      table("test_resource")
      keyspace("ash_scylla_test")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule TestResourceForReadTimeout do
    use Ash.Resource,
      domain: AshScylla.TestDomain,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(MockReadTimeoutRepo)
      table("test_resource")
      keyspace("ash_scylla_test")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defp base_query do
    %Query{
      table: "test_resource",
      filters: [],
      sorts: [],
      limit: 10,
      select: nil,
      distinct: nil,
      tenant: nil,
      context: %{},
      atomic: nil,
      upsert?: false,
      upsert_fields: [],
      upsert_identity: nil,
      keyset: nil,
      aggregates: [],
      group_by: nil
    }
  end

  defp changeset_for_timeout do
    %Ash.Changeset{
      resource: TestResourceForTimeout,
      attributes: %{name: "test"},
      filter: []
    }
  end

  defp changeset_for_read_timeout do
    %Ash.Changeset{
      resource: TestResourceForReadTimeout,
      filter: []
    }
  end

  # A filter that will trigger unknown_filter error - non-serializable type
  defp invalid_filter do
    # A function is not serializable and will trigger unknown_filter
    fn -> :ok end
  end

  describe "update_query error handling" do
    test "wraps Xandra error from repo.query via handle_result" do
      query = base_query()
      changeset = changeset_for_timeout()

      result = DataLayer.update_query(query, changeset, TestResourceForTimeout, [])

      assert {:error, %ScyllaError{type: :timeout, message: message}} = result
      assert message =~ "Query timeout"
    end
  end

  describe "destroy_query error handling" do
    test "wraps Xandra error from repo.query via handle_result" do
      query = base_query()
      changeset = changeset_for_read_timeout()

      result = DataLayer.destroy_query(query, changeset, [], TestResourceForReadTimeout)

      assert {:error, %ScyllaError{type: :timeout, message: message}} = result
      assert message =~ "Query timeout"
    end
  end

  describe "run_aggregate_query error handling" do
    test "wraps Xandra error from repo.query via handle_result" do
      query = base_query()
      aggregates = [%{kind: :count, name: :total}]

      result = DataLayer.run_aggregate_query(query, aggregates, TestResourceForError)

      assert {:error, %ScyllaError{type: :overloaded, message: message}} = result
      assert message =~ "overloaded"
    end
  end

  describe "unknown filter error (centralized unknown_filter_error!)" do
    test "run_query raises centralized error for unknown filter (non-serializable)" do
      query = %{base_query() | filters: [invalid_filter()]}

      assert_raise AshScylla.Error, fn ->
        DataLayer.run_query(query, TestResourceForError)
      end
    end

    test "update_query raises centralized error for unknown filter (non-serializable)" do
      query = %{base_query() | filters: [invalid_filter()]}

      changeset = %Ash.Changeset{
        resource: TestResourceForError,
        filter: [invalid_filter()]
      }

      assert_raise AshScylla.Error, fn ->
        DataLayer.update_query(query, changeset, TestResourceForError, [])
      end
    end

    test "destroy_query raises centralized error for unknown filter (non-serializable)" do
      query = %{base_query() | filters: [invalid_filter()]}

      changeset = %Ash.Changeset{
        resource: TestResourceForError,
        filter: [invalid_filter()]
      }

      assert_raise AshScylla.Error, fn ->
        DataLayer.destroy_query(query, changeset, [], TestResourceForError)
      end
    end

    test "run_aggregate_query raises centralized error for unknown filter (non-serializable)" do
      query = %{base_query() | filters: [invalid_filter()]}
      aggregates = [%{kind: :count, name: :total}]

      assert_raise AshScylla.Error, fn ->
        DataLayer.run_aggregate_query(query, aggregates, TestResourceForError)
      end
    end

    test "error message is consistent across all paths" do
      filter = [invalid_filter()]
      query = %{base_query() | filters: filter}

      changeset = %Ash.Changeset{
        resource: TestResourceForError,
        filter: filter
      }

      aggregates = [%{kind: :count, name: :total}]

      errors = [
        try do
          DataLayer.run_query(query, TestResourceForError)
        rescue
          e -> e
        end,
        try do
          DataLayer.update_query(query, changeset, TestResourceForError, [])
        rescue
          e -> e
        end,
        try do
          DataLayer.destroy_query(query, changeset, [], TestResourceForError)
        rescue
          e -> e
        end,
        try do
          DataLayer.run_aggregate_query(query, aggregates, TestResourceForError)
        rescue
          e -> e
        end
      ]

      # All should have the same error message
      messages = Enum.map(errors, & &1.message)
      assert Enum.uniq(messages) |> length() == 1
      assert Enum.at(messages, 0) =~ "Unable to translate filter expression to CQL"
    end
  end
end
