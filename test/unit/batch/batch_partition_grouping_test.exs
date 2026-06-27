defmodule AshScylla.BatchPartitionGroupingTest do
  @moduledoc """
  Tests to verify that batch operations correctly group by partition key.
  Covers: Issue #9 (Batch.batch_insert_async grouping heuristic is weak)
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer.Batch

  # Mock repo that tracks batch groupings
  defmodule GroupingRepo do
    @moduledoc false

    def start_link do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def get_batches do
      Agent.get(__MODULE__, & &1)
    end

    def clear_batches do
      Agent.update(__MODULE__, fn _ -> [] end)
    end

    def query(_q, _p, _opts \\ []) do
      Agent.update(__MODULE__, fn batches -> [:batch_called | batches] end)
      {:ok, %{}}
    end
  end

  # Resource with composite partition key
  defmodule CompositePKResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    attributes do
      attribute :org_id, :uuid do
        primary_key?(true)
        allow_nil?(false)
      end

      attribute :user_id, :uuid do
        primary_key?(true)
        allow_nil?(false)
      end

      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read])
    end
  end

  # Resource with single partition key
  defmodule SinglePKResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read])
    end
  end

  describe "batch_insert_async/3 — partition-aware grouping" do
    setup do
      case GroupingRepo.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      GroupingRepo.clear_batches()
      :ok
    end

    test "groups statements by first param (single PK resource)" do
      statements = [
        {"INSERT INTO t (id, name) VALUES (?, ?)", ["id_1", "Alice"]},
        {"INSERT INTO t (id, name) VALUES (?, ?)", ["id_2", "Bob"]},
        {"INSERT INTO t (id, name) VALUES (?, ?)", ["id_3", "Charlie"]}
      ]

      assert {:ok, _results} =
               Batch.batch_insert_async(GroupingRepo, statements,
                 resource: SinglePKResource,
                 max_concurrency: 1
               )

      # Verify the batch was executed
      batches = GroupingRepo.get_batches()
      assert batches != []
    end

    test "returns error when any batch fails" do
      defmodule FailingRepo do
        @moduledoc false
        def query(_q, _p, _opts \\ []), do: {:error, :batch_failed}
      end

      statements = [
        {"INSERT INTO t (id, name) VALUES (?, ?)", ["id_1", "Alice"]}
      ]

      assert {:error, :batch_failed} =
               Batch.batch_insert_async(FailingRepo, statements, resource: SinglePKResource)
    end

    test "handles empty statement list" do
      assert {:ok, []} =
               Batch.batch_insert_async(GroupingRepo, [], resource: SinglePKResource)
    end

    test "respects max_concurrency setting" do
      statements =
        for i <- 1..20 do
          {"INSERT INTO t (id) VALUES (?)", ["id_#{i}"]}
        end

      assert {:ok, _results} =
               Batch.batch_insert_async(GroupingRepo, statements,
                 resource: SinglePKResource,
                 max_concurrency: 2
               )
    end
  end

  describe "partition_key/2 — PK extraction" do
    test "extracts single primary key" do
      record = %{id: "uuid-123", name: "Alice"}
      result = Batch.partition_key(record, SinglePKResource)
      assert result == %{id: "uuid-123"}
    end

    test "extracts composite primary key" do
      record = %{org_id: "org-1", user_id: "user-1", name: "Alice"}
      result = Batch.partition_key(record, CompositePKResource)
      assert result == %{org_id: "org-1", user_id: "user-1"}
    end

    test "returns empty map when no PK fields present" do
      record = %{name: "Alice"}
      result = Batch.partition_key(record, SinglePKResource)
      assert result == %{}
    end

    test "handles nil PK values" do
      record = %{id: nil, name: "Alice"}
      result = Batch.partition_key(record, SinglePKResource)
      assert result == %{id: nil}
    end
  end

  describe "build_batch_query/3 — statement validation" do
    defmodule ValidatingRepo do
      @moduledoc false
      def query(_q, _p, _opts \\ []), do: {:ok, %{}}
    end

    test "raises for malformed statements" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_insert(ValidatingRepo, [{"query", "not_a_list"}])
      end
    end

    test "raises for nil statements" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_insert(ValidatingRepo, [nil])
      end
    end

    test "raises for non-string query" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_insert(ValidatingRepo, [{:atom_query, []}])
      end
    end

    test "accepts valid batch statements" do
      statements = [
        {"INSERT INTO t (id, name) VALUES (?, ?)", [1, "Alice"]},
        {"INSERT INTO t (id, name) VALUES (?, ?)", [2, "Bob"]}
      ]

      assert {:ok, _} = Batch.batch_insert(ValidatingRepo, statements)
    end

    test "accepts empty batch" do
      assert {:ok, []} = Batch.batch_insert(ValidatingRepo, [])
    end
  end
end
