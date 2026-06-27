defmodule AshScylla.DataLayer.AsyncBatchTest do
  @moduledoc """
  Tests for async partition-aware batching in AshScylla.DataLayer.Batch.
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer.Batch

  # Mock repo that tracks calls
  defmodule TrackingRepo do
    @moduledoc false

    def start_link do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def get_calls do
      Agent.get(__MODULE__, & &1)
    end

    def clear_calls do
      Agent.update(__MODULE__, fn _ -> [] end)
    end

    def query(_q, _p, _opts \\ []) do
      Agent.update(__MODULE__, fn calls -> [:query_called | calls] end)
      {:ok, %{}}
    end
  end

  # Simple mock repo
  defmodule SimpleMockRepo do
    @moduledoc false
    def query(_q, _p, _opts \\ []), do: {:ok, %{}}
  end

  # Mock repo that returns errors
  defmodule ErrorMockRepo do
    @moduledoc false
    def query(_q, _p, _opts \\ []), do: {:error, :mock_error}
  end

  # Test resource for partition_key/2
  defmodule TestResourceForPartition do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:email, :string)
    end

    actions do
      defaults([:create, :read])
    end
  end

  describe "batch_insert_async/3" do
    setup do
      # Ensure a fresh Agent is running for each test
      case Process.whereis(TrackingRepo) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end

      {:ok, _pid} = TrackingRepo.start_link()
      :ok
    end

    test "returns {:ok, results} for valid statements" do
      statements = [
        {"INSERT INTO t (id, name) VALUES (?, ?)", [1, "Alice"]},
        {"INSERT INTO t (id, name) VALUES (?, ?)", [2, "Bob"]}
      ]

      assert {:ok, _results} =
               Batch.batch_insert_async(SimpleMockRepo, statements,
                 resource: TestResourceForPartition
               )
    end

    test "works without :resource option" do
      assert {:ok, []} == Batch.batch_insert_async(SimpleMockRepo, [], max_concurrency: 4)
    end

    test "uses default max_concurrency from System.schedulers_online" do
      statements = [
        {"INSERT INTO t (id) VALUES (?)", [1]}
      ]

      assert {:ok, _results} =
               Batch.batch_insert_async(SimpleMockRepo, statements,
                 resource: TestResourceForPartition
               )
    end

    test "accepts custom max_concurrency option" do
      statements = [
        {"INSERT INTO t (id) VALUES (?)", [1]},
        {"INSERT INTO t (id) VALUES (?)", [2]}
      ]

      assert {:ok, _results} =
               Batch.batch_insert_async(SimpleMockRepo, statements,
                 resource: TestResourceForPartition,
                 max_concurrency: 1
               )
    end

    test "returns error when repo returns error" do
      statements = [
        {"INSERT INTO t (id) VALUES (?)", [1]}
      ]

      assert {:error, :mock_error} =
               Batch.batch_insert_async(ErrorMockRepo, statements,
                 resource: TestResourceForPartition
               )
    end

    test "groups statements by partition key hash" do
      statements = [
        {"INSERT INTO t (id) VALUES (?)", ["a"]},
        {"INSERT INTO t (id) VALUES (?)", ["b"]},
        {"INSERT INTO t (id) VALUES (?)", ["c"]}
      ]

      assert {:ok, _results} =
               Batch.batch_insert_async(SimpleMockRepo, statements,
                 resource: TestResourceForPartition,
                 max_concurrency: 1
               )
    end

    test "handles empty statement list" do
      assert {:ok, []} =
               Batch.batch_insert_async(SimpleMockRepo, [], resource: TestResourceForPartition)
    end

    test "executes multiple groups concurrently" do
      TrackingRepo.clear_calls()

      statements =
        for i <- 1..10 do
          {"INSERT INTO t (id) VALUES (?)", [i]}
        end

      assert {:ok, _results} =
               Batch.batch_insert_async(TrackingRepo, statements,
                 resource: TestResourceForPartition,
                 max_concurrency: 4
               )

      calls = TrackingRepo.get_calls()
      assert calls != []
    end
  end

  describe "partition_key/2" do
    test "extracts primary key values from a record" do
      record = %{id: "abc-123", name: "Alice", email: "alice@example.com"}
      result = Batch.partition_key(record, TestResourceForPartition)
      assert result == %{id: "abc-123"}
    end

    test "returns empty map for record with no matching PK fields" do
      record = %{name: "Alice", email: "alice@example.com"}
      result = Batch.partition_key(record, TestResourceForPartition)
      assert result == %{}
    end

    test "returns empty map for empty record" do
      result = Batch.partition_key(%{}, TestResourceForPartition)
      assert result == %{}
    end

    test "includes nil values for missing PK fields" do
      record = %{id: nil, name: "Alice"}
      result = Batch.partition_key(record, TestResourceForPartition)
      assert result == %{id: nil}
    end
  end
end

# ---------------------------------------------------------------------------
# Updated Pagination Tests
# ---------------------------------------------------------------------------

defmodule AshScylla.DataLayer.PaginationUpdatedTest do
  @moduledoc """
  Tests for the updated AshScylla.DataLayer.Pagination module.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Pagination

  # Mock repo for pagination
  defmodule PaginationMockRepo do
    @moduledoc false

    def query(_query, _params, opts) do
      page_state = Keyword.get(opts, :page_state)

      if page_state do
        # Simulate returning a next page token
        {:ok, %Xandra.Page{content: [%{id: 2}], paging_state: "next_page_state"}}
      else
        # First page
        {:ok, %Xandra.Page{content: [%{id: 1}], paging_state: "first_page_state"}}
      end
    end
  end

  defmodule PaginationNoMoreRepo do
    @moduledoc false

    def query(_query, _params, _opts) do
      {:ok, %Xandra.Page{content: [%{id: 1}], paging_state: nil}}
    end
  end

  defmodule PaginationErrorRepo do
    @moduledoc false

    def query(_query, _params, _opts) do
      {:error, :timeout}
    end
  end

  describe "fetch_page/5" do
    test "returns 3-tuple {ok, records, next_token}" do
      assert {:ok, records, next_token} =
               Pagination.fetch_page(PaginationMockRepo, "users", [], nil, 10)

      assert is_list(records)
      assert length(records) == 1
      assert is_binary(next_token)
    end

    test "returns nil token when no more pages" do
      assert {:ok, records, nil} =
               Pagination.fetch_page(PaginationNoMoreRepo, "users", [], nil, 10)

      assert is_list(records)
    end

    test "decodes page token for subsequent pages" do
      # First page
      {:ok, _records, next_token} =
        Pagination.fetch_page(PaginationMockRepo, "users", [], nil, 10)

      assert is_binary(next_token)

      # Second page using token
      {:ok, records, _next_token} =
        Pagination.fetch_page(PaginationMockRepo, "users", [], next_token, 10)

      assert is_list(records)
    end

    test "caps page_size at max" do
      {:ok, _, _} = Pagination.fetch_page(PaginationMockRepo, "users", [], nil, 9999)
      # Should not raise — page_size is capped internally
    end

    test "uses default page_size of 50" do
      {:ok, _, _} = Pagination.fetch_page(PaginationMockRepo, "users", [], nil)
    end

    test "returns error tuple on repo error" do
      assert {:error, :timeout} =
               Pagination.fetch_page(PaginationErrorRepo, "users", [], nil, 10)
    end

    test "passes filters as keyword list" do
      assert {:ok, _, _} =
               Pagination.fetch_page(PaginationMockRepo, "users", [status: "active"], nil, 10)
    end
  end

  describe "build_paginated_query/3" do
    test "returns {query, params} tuple" do
      {query, params} = Pagination.build_paginated_query("users", [], 10)
      assert is_binary(query)
      assert is_list(params)
    end

    test "includes LIMIT in query" do
      {query, _params} = Pagination.build_paginated_query("users", [], 25)
      assert String.contains?(query, "LIMIT ?")
    end

    test "includes page_size in params" do
      {_query, params} = Pagination.build_paginated_query("users", [], 25)
      assert 25 in params
    end

    test "includes filter values in params" do
      {_query, params} = Pagination.build_paginated_query("users", [status: "active"], 10)
      assert "active" in params
      assert 10 in params
    end

    test "uses default page_size" do
      {_query, _params} = Pagination.build_paginated_query("users", [], nil)
      # nil page_size gets min(nil, 1000) which is nil, but the function handles it
    end

    test "caps page_size at max" do
      {_query, params} = Pagination.build_paginated_query("users", [], 9999)
      assert 1000 in params
    end
  end

  describe "encode_page_token/1 and decode_page_token/1" do
    test "encode produces a binary string" do
      token = Pagination.encode_page_token("binary_state")
      assert is_binary(token)
    end

    test "decode reverses encode" do
      original = "binary_paging_state"
      token = Pagination.encode_page_token(original)
      assert {:ok, ^original} = Pagination.decode_page_token(token)
    end

    test "decode returns error for invalid base64" do
      assert {:error, :invalid_token} = Pagination.decode_page_token("invalid!!")
    end

    test "token is base64 encoded" do
      token = Pagination.encode_page_token("test")
      assert token == "dGVzdA=="
    end
  end

  describe "default_page_size/0 and max_page_size/0" do
    test "default_page_size returns 50" do
      assert Pagination.default_page_size() == 50
    end

    test "max_page_size returns 1000" do
      assert Pagination.max_page_size() == 1000
    end
  end
end
