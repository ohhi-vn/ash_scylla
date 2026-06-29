defmodule AshScylla.WorkloadTest do
  @moduledoc """
  Lightweight workload tests for AshScylla major features.

  These tests exercise the system under realistic concurrent patterns
  to ensure smooth operation. They are NOT benchmarks — they verify
  correctness under load, not performance numbers.

  All tests use mock repos (no ScyllaDB needed) and focus on:
  - Concurrent query building
  - Concurrent filter validation
  - Prepared statement cache under concurrent access
  - Telemetry event emission under concurrent spans
  - Async batch execution with multiple groups
  - Pagination token encode/decode under concurrent access
  - Mixed read/write workload simulation
  - Error handling under concurrent failures
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.Batch
  alias AshScylla.DataLayer.Dsl
  alias AshScylla.DataLayer.FilterValidator
  alias AshScylla.DataLayer.Pagination
  alias AshScylla.DataLayer.QueryBuilder
  alias AshScylla.PreparedStatementCache
  alias AshScylla.Telemetry

  # ---------------------------------------------------------------------------
  # Shared test fixtures
  # ---------------------------------------------------------------------------

  defmodule WorkloadResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      table("workload_test")
      keyspace("workload_ks")
      consistency(:quorum)
      ttl(3600)
      pagination(:token)

      secondary_index(:email)
      secondary_index(:status)
      per_action_consistency(read: :one, create: :quorum)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:email, :string)
      attribute(:status, :string)
      attribute(:age, :integer)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule WorkloadMockRepo do
    @moduledoc false

    def query(_q, _p, _opts \\ []) do
      # Simulate minimal latency
      Process.sleep(1)
      {:ok, %{rows: [], paging_state: nil}}
    end

    def prepare(cql, _opts) do
      {:ok, {:prepared_stmt, cql}}
    end
  end

  defmodule SlowMockRepo do
    @moduledoc false

    def query(_q, _p, _opts \\ []) do
      Process.sleep(5)
      {:ok, %{rows: [%{id: "test-id", name: "Test"}], paging_state: nil}}
    end
  end

  defmodule FailingMockRepo do
    @moduledoc false

    def query(_q, _p, _opts \\ []) do
      {:error, :mock_error}
    end
  end

  # ---------------------------------------------------------------------------
  # 1. Concurrent Query Building
  # ---------------------------------------------------------------------------

  describe "concurrent query building" do
    test "builds 100 queries concurrently without errors" do
      tasks =
        Enum.map(1..100, fn i ->
          Task.async(fn ->
            QueryBuilder.build_optimized_query(%AshScylla.Query{
              resource: WorkloadResource,
              repo: nil,
              table: "workload_test",
              filters: [
                %{operator: :eq, left: %{name: :status}, right: %{value: "active"}},
                %{operator: :gt, left: %{name: :age}, right: %{value: i}}
              ],
              sorts: [{:name, :asc}],
              limit: 25,
              select: [:id, :name, :email],
              tenant: nil
            })
          end)
        end)

      results = Task.await_many(tasks, 30_000)
      assert length(results) == 100

      Enum.each(results, fn {cql, params} ->
        assert is_binary(cql)
        assert is_list(params)
        assert String.contains?(cql, "SELECT")
        assert String.contains?(cql, "WHERE")
        assert String.contains?(cql, "ORDER BY")
        assert String.contains?(cql, "LIMIT")
      end)
    end

    test "builds queries with varying complexity concurrently" do
      tasks = [
        # Simple select all
        Task.async(fn ->
          QueryBuilder.build_optimized_query(%AshScylla.Query{
            table: "t",
            filters: [],
            sorts: [],
            limit: nil,
            select: nil,
            resource: nil,
            repo: nil,
            tenant: nil
          })
        end),
        # Complex with many filters
        Task.async(fn ->
          filters =
            Enum.map(1..10, fn i ->
              %{operator: :eq, left: %{name: :"col_#{i}"}, right: %{value: i}}
            end)

          QueryBuilder.build_optimized_query(%AshScylla.Query{
            table: "t",
            filters: filters,
            sorts: [{:a, :asc}, {:b, :desc}],
            limit: 100,
            select: [:a, :b, :c],
            resource: nil,
            repo: nil,
            tenant: nil
          })
        end),
        # IN operator
        Task.async(fn ->
          QueryBuilder.build_optimized_query(%AshScylla.Query{
            table: "t",
            filters: [%{operator: :in, left: %{name: :id}, right: %{value: Enum.to_list(1..50)}}],
            sorts: [],
            limit: 10,
            select: nil,
            resource: nil,
            repo: nil,
            tenant: nil
          })
        end)
      ]

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 3

      [{simple_cql, _}, {complex_cql, _complex_params}, {in_cql, in_params}] = results
      assert simple_cql == "SELECT * FROM t"
      assert String.contains?(complex_cql, "ORDER BY a asc, b desc")
      assert String.contains?(in_cql, "IN")
      assert length(in_params) == 51
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Concurrent Filter Validation
  # ---------------------------------------------------------------------------

  describe "concurrent filter validation" do
    test "validates filters concurrently across different resources" do
      tasks =
        Enum.map(1..50, fn _i ->
          Task.async(fn ->
            FilterValidator.validate_filters(WorkloadResource, [
              %{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}}
            ])
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "concurrent validation catches invalid filters" do
      tasks =
        Enum.map(1..20, fn _i ->
          Task.async(fn ->
            try do
              FilterValidator.validate_filters(WorkloadResource, [
                %{operator: :eq, left: %{name: :nonexistent}, right: %{value: "x"}}
              ])

              :no_error
            rescue
              e in AshScylla.Error -> {:error, e.message}
            end
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 20

      assert Enum.all?(results, fn
               {:error, msg} -> String.contains?(msg, "requires a secondary index")
               _ -> false
             end)
    end

    test "mixed valid and invalid filters under concurrent load" do
      valid_task = fn ->
        Task.async(fn ->
          FilterValidator.validate_filters(WorkloadResource, [
            %{operator: :eq, left: %{name: :id}, right: %{value: "uuid-123"}}
          ])
        end)
      end

      invalid_task = fn ->
        Task.async(fn ->
          try do
            FilterValidator.validate_filters(WorkloadResource, [
              %{operator: :eq, left: %{name: :created_at}, right: %{value: "2024-01-01"}}
            ])

            :no_error
          rescue
            _ -> :caught_error
          end
        end)
      end

      tasks =
        Enum.map(1..40, fn i -> if rem(i, 2) == 0, do: valid_task.(), else: invalid_task.() end)

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 40

      {oks, errors} = Enum.split_with(results, &(&1 == :ok))
      assert length(oks) == 20
      assert length(errors) == 20
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Prepared Statement Cache Under Concurrent Access
  # ---------------------------------------------------------------------------

  describe "prepared statement cache under concurrent access" do
    setup do
      case PreparedStatementCache.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      :ok
    end

    test "concurrent prepare calls don't crash" do
      cqls = Enum.map(1..20, fn i -> "SELECT * FROM t#{i} WHERE id = ?" end)

      tasks =
        Enum.map(cqls, fn cql ->
          Task.async(fn ->
            PreparedStatementCache.prepare(WorkloadMockRepo, cql)
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 20

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      assert PreparedStatementCache.size() == 20
    end

    test "concurrent reads of same CQL return cached result" do
      cql = "SELECT * FROM users WHERE id = ?"

      # Prime the cache
      {:ok, stmt} = PreparedStatementCache.prepare(WorkloadMockRepo, cql)

      tasks =
        Enum.map(1..50, fn _i ->
          Task.async(fn ->
            PreparedStatementCache.prepare(WorkloadMockRepo, cql)
          end)
        end)

      results = Task.await_many(tasks, 15_000)

      assert Enum.all?(results, fn
               {:ok, ^stmt} -> true
               _ -> false
             end)

      assert PreparedStatementCache.size() == 1
    end

    test "concurrent prepare and invalidate don't crash" do
      cql = "SELECT * FROM t WHERE id = ?"

      tasks =
        Enum.map(1..30, fn i ->
          Task.async(fn ->
            case rem(i, 3) do
              0 -> PreparedStatementCache.prepare(WorkloadMockRepo, cql)
              1 -> PreparedStatementCache.invalidate(cql)
              2 -> PreparedStatementCache.size()
            end
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 30
    end

    test "cache survives high concurrent churn" do
      tasks =
        Enum.map(1..100, fn i ->
          Task.async(fn ->
            cql = "SELECT * FROM t#{rem(i, 10)} WHERE id = ?"
            PreparedStatementCache.prepare(WorkloadMockRepo, cql)
          end)
        end)

      Task.await_many(tasks, 30_000)
      # At most 10 unique CQLs
      assert PreparedStatementCache.size() <= 10
      assert PreparedStatementCache.size() >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Telemetry Under Concurrent Spans
  # ---------------------------------------------------------------------------

  describe "telemetry under concurrent spans" do
    test "emits correct events for 50 concurrent spans" do
      test_pid = self()

      :telemetry.attach(
        "workload-test-stop",
        [:ash_scylla, :query, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_stop, measurements, metadata})
        end,
        nil
      )

      tasks =
        Enum.map(1..50, fn i ->
          Task.async(fn ->
            Telemetry.span(WorkloadResource, :read, "SELECT * FROM t WHERE id = #{i}", fn ->
              Process.sleep(1)
              {:ok, i}
            end)
          end)
        end)

      results = Task.await_many(tasks, 30_000)
      assert length(results) == 50

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      # Collect telemetry messages
      messages = collect_telemetry_messages(50, 15_000)
      assert length(messages) == 50

      Enum.each(messages, fn {:telemetry_stop, measurements, metadata} ->
        assert is_map(measurements)
        assert Map.has_key?(measurements, :duration)
        assert measurements.duration >= 0
        assert metadata.resource == WorkloadResource
        assert metadata.operation == :read
      end)

      :telemetry.detach("workload-test-stop")
    end

    test "concurrent batch spans emit correct events" do
      test_pid = self()

      :telemetry.attach(
        "workload-batch-stop",
        [:ash_scylla, :batch, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:batch_stop, measurements, metadata})
        end,
        nil
      )

      tasks =
        Enum.map(1..20, fn i ->
          Task.async(fn ->
            Telemetry.batch_span(WorkloadResource, :insert, i * 10, fn ->
              Process.sleep(1)
              {:ok, :completed}
            end)
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 20

      messages = collect_telemetry_messages(20, 15_000)
      assert length(messages) == 20

      Enum.each(messages, fn {:batch_stop, _measurements, metadata} ->
        assert metadata.resource == WorkloadResource
        assert metadata.operation == :insert
        assert is_integer(metadata.batch_size)
      end)

      :telemetry.detach("workload-batch-stop")
    end

    test "concurrent exception spans emit exception events" do
      test_pid = self()

      :telemetry.attach(
        "workload-exception",
        [:ash_scylla, :query, :exception],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:exception_event, measurements, metadata})
        end,
        nil
      )

      tasks =
        Enum.map(1..10, fn i ->
          Task.async(fn ->
            try do
              Telemetry.span(WorkloadResource, :write, "INSERT INTO t", fn ->
                raise "error-#{i}"
              end)
            rescue
              _ -> :caught
            end
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert Enum.all?(results, &(&1 == :caught))

      messages = collect_telemetry_messages(10, 15_000)
      assert length(messages) == 10

      Enum.each(messages, fn {:exception_event, measurements, metadata} ->
        assert measurements.duration >= 0
        assert metadata.kind == :error
      end)

      :telemetry.detach("workload-exception")
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Async Batch Execution
  # ---------------------------------------------------------------------------

  describe "async batch execution" do
    test "processes 500 statements across multiple partition groups" do
      statements =
        Enum.map(1..500, fn i ->
          {"INSERT INTO t (id, name) VALUES (?, ?)", [i, "User#{i}"]}
        end)

      assert {:ok, _results} =
               Batch.batch_insert_async(WorkloadMockRepo, statements,
                 resource: WorkloadResource,
                 max_concurrency: 8
               )
    end

    test "handles single-statement batch" do
      statements = [{"INSERT INTO t (id) VALUES (?)", [1]}]

      assert {:ok, _results} =
               Batch.batch_insert_async(WorkloadMockRepo, statements, resource: WorkloadResource)
    end

    test "propagates errors from one group without affecting others" do
      statements =
        Enum.map(1..20, fn i ->
          {"INSERT INTO t (id) VALUES (?)", [i]}
        end)

      assert {:error, :mock_error} =
               Batch.batch_insert_async(FailingMockRepo, statements,
                 resource: WorkloadResource,
                 max_concurrency: 4
               )
    end

    test "concurrent async batches don't interfere" do
      batch1 = Enum.map(1..50, fn i -> {"INSERT INTO t1 (id) VALUES (?)", [i]} end)
      batch2 = Enum.map(1..50, fn i -> {"INSERT INTO t2 (id) VALUES (?)", [i]} end)

      tasks = [
        Task.async(fn ->
          Batch.batch_insert_async(WorkloadMockRepo, batch1,
            resource: WorkloadResource,
            max_concurrency: 4
          )
        end),
        Task.async(fn ->
          Batch.batch_insert_async(WorkloadMockRepo, batch2,
            resource: WorkloadResource,
            max_concurrency: 4
          )
        end)
      ]

      results = Task.await_many(tasks, 30_000)

      assert Enum.all?(results, fn
               {:ok, _list} -> true
               _ -> false
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Pagination Under Concurrent Access
  # ---------------------------------------------------------------------------

  describe "pagination under concurrent access" do
    test "concurrent token encode/decode is consistent" do
      states = Enum.map(1..100, fn i -> "paging_state_#{i}" end)

      tasks =
        Enum.map(states, fn state ->
          Task.async(fn ->
            token = Pagination.encode_page_token(state)
            decoded = Pagination.decode_page_token(token)
            {state, token, decoded}
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 100

      Enum.each(results, fn {original, token, {:ok, decoded}} ->
        assert is_binary(token)
        assert decoded == original
      end)
    end

    test "concurrent build_paginated_query with varying filters" do
      tasks =
        Enum.map(1..50, fn i ->
          Task.async(fn ->
            filters =
              case rem(i, 3) do
                0 -> [status: "active"]
                1 -> [status: "active", age: i]
                2 -> []
              end

            page_size = 10 + rem(i, 90)
            _token = if rem(i, 2) == 0, do: Pagination.encode_page_token("token_#{i}"), else: nil
            Pagination.build_paginated_query("users", filters, page_size)
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 50

      Enum.each(results, fn {query, params} ->
        assert is_binary(query)
        assert String.contains?(query, "SELECT * FROM users")
        assert String.contains?(query, "LIMIT ?")
        assert is_list(params)
      end)
    end

    test "page_size cap is respected under concurrent access" do
      tasks =
        Enum.map(1..30, fn i ->
          Task.async(fn ->
            {_query, params} = Pagination.build_paginated_query("t", [], i * 100)
            params
          end)
        end)

      results = Task.await_many(tasks, 15_000)

      Enum.each(results, fn params ->
        page_size = List.last(params)
        assert page_size <= 1000
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # 7. Mixed Read/Write Workload Simulation
  # ---------------------------------------------------------------------------

  describe "mixed read/write workload simulation" do
    test "simulates 80/20 read/write workload" do
      total = 100
      read_count = 80
      write_count = 20

      read_tasks =
        Enum.map(1..read_count, fn i ->
          Task.async(fn ->
            QueryBuilder.build_optimized_query(%AshScylla.Query{
              table: "users",
              filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "uuid-#{i}"}}],
              sorts: [],
              limit: 1,
              select: nil,
              resource: WorkloadResource,
              repo: nil,
              tenant: nil
            })
          end)
        end)

      write_tasks =
        Enum.map(1..write_count, fn i ->
          Task.async(fn ->
            statements = [
              {"INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
               ["uuid-#{i}", "User#{i}", "user#{i}@example.com"]}
            ]

            Batch.batch_insert_async(WorkloadMockRepo, statements,
              resource: WorkloadResource,
              max_concurrency: 2
            )
          end)
        end)

      all_tasks = read_tasks ++ write_tasks
      results = Task.await_many(all_tasks, 30_000)
      assert length(results) == total

      {read_results, write_results} = Enum.split(results, read_count)

      Enum.each(read_results, fn {cql, _params} ->
        assert String.contains?(cql, "SELECT")
      end)

      Enum.each(write_results, fn
        {:ok, _list} -> :ok
        other -> flunk("Unexpected: #{inspect(other)}")
      end)
    end

    test "simulates burst traffic with 200 concurrent operations" do
      tasks =
        Enum.map(1..200, fn i ->
          Task.async(fn ->
            case rem(i, 4) do
              0 ->
                # Read query
                QueryBuilder.build_optimized_query(%AshScylla.Query{
                  table: "users",
                  filters: [],
                  sorts: [{:name, :asc}],
                  limit: 10,
                  select: [:id, :name],
                  resource: nil,
                  repo: nil,
                  tenant: nil
                })

              1 ->
                # Filter validation
                FilterValidator.validate_filters(WorkloadResource, [
                  %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
                ])

              2 ->
                # Batch insert
                statements = [{"INSERT INTO t (id) VALUES (?)", [i]}]

                Batch.batch_insert_async(WorkloadMockRepo, statements,
                  resource: WorkloadResource,
                  max_concurrency: 8
                )

              3 ->
                # Pagination
                Pagination.build_paginated_query("users", [status: "active"], 25)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)
      assert length(results) == 200
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Error Handling Under Concurrent Failures
  # ---------------------------------------------------------------------------

  describe "error handling under concurrent failures" do
    test "concurrent filter validation errors are independent" do
      tasks =
        Enum.map(1..20, fn i ->
          Task.async(fn ->
            try do
              FilterValidator.validate_filters(WorkloadResource, [
                %{operator: :eq, left: %{name: :"bad_col_#{i}"}, right: %{value: "x"}}
              ])

              :no_error
            rescue
              e in AshScylla.Error ->
                {:error, String.contains?(e.message, "bad_col_#{i}")}
            end
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 20

      assert Enum.all?(results, fn
               {:error, true} -> true
               _ -> false
             end)
    end

    test "batch errors don't crash other concurrent batches" do
      ok_statements = Enum.map(1..10, fn i -> {"INSERT INTO t (id) VALUES (?)", [i]} end)
      fail_statements = Enum.map(1..10, fn i -> {"INSERT INTO t (id) VALUES (?)", [i]} end)

      tasks = [
        Task.async(fn ->
          Batch.batch_insert_async(WorkloadMockRepo, ok_statements,
            resource: WorkloadResource,
            max_concurrency: 2
          )
        end),
        Task.async(fn ->
          Batch.batch_insert_async(FailingMockRepo, fail_statements,
            resource: WorkloadResource,
            max_concurrency: 2
          )
        end),
        Task.async(fn ->
          Batch.batch_insert_async(WorkloadMockRepo, ok_statements,
            resource: WorkloadResource,
            max_concurrency: 2
          )
        end)
      ]

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 3
      assert {:ok, _list} = Enum.at(results, 0)
      assert {:error, :mock_error} = Enum.at(results, 1)
      assert {:ok, _list} = Enum.at(results, 2)
    end

    test "DSL getters work correctly under concurrent access" do
      tasks =
        Enum.map(1..50, fn _i ->
          Task.async(fn ->
            %{
              table: Dsl.table(WorkloadResource),
              keyspace: Dsl.keyspace(WorkloadResource),
              consistency: Dsl.consistency(WorkloadResource),
              ttl: Dsl.ttl(WorkloadResource),
              pagination: Dsl.pagination(WorkloadResource),
              per_action_consistency: Dsl.per_action_consistency(WorkloadResource),
              secondary_indexes: Dsl.secondary_indexes(WorkloadResource)
            }
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 50

      Enum.each(results, fn result ->
        assert result.table == "workload_test"
        assert result.keyspace == "workload_ks"
        assert result.consistency == :quorum
        assert result.ttl == 3600
        assert result.pagination == :token
        assert result.per_action_consistency[:read] == :one
        assert result.per_action_consistency[:create] == :quorum
        assert length(result.secondary_indexes) == 2
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # 9. Data Layer Query Struct Operations Under Load
  # ---------------------------------------------------------------------------

  describe "data layer query struct operations under load" do
    test "concurrent filter/sort/limit/offset operations on query struct" do
      base_query = %AshScylla.Query{
        resource: WorkloadResource,
        repo: nil,
        table: "users",
        filters: [],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      tasks =
        Enum.map(1..50, fn i ->
          Task.async(fn ->
            base_query
            |> DataLayer.filter(
              %{operator: :eq, left: %{name: :status}, right: %{value: "active"}},
              WorkloadResource
            )
            |> elem(1)
            |> DataLayer.sort([{:name, :asc}], WorkloadResource)
            |> elem(1)
            |> DataLayer.limit(10 + i, WorkloadResource)
            |> elem(1)
            |> DataLayer.select([:id, :name], WorkloadResource)
            |> elem(1)
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 50

      Enum.with_index(results, fn query, i ->
        assert length(query.filters) == 1
        assert length(query.sorts) == 1
        assert query.limit == 10 + i + 1
        assert query.select == [:id, :name]
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # 10. End-to-End Feature Interaction
  # ---------------------------------------------------------------------------

  describe "end-to-end feature interaction" do
    test "full pipeline: validate -> build query -> emit telemetry" do
      test_pid = self()

      :telemetry.attach(
        "e2e-stop",
        [:ash_scylla, :query, :stop],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:e2e_telemetry, metadata})
        end,
        nil
      )

      tasks =
        Enum.map(1..30, fn i ->
          Task.async(fn ->
            # Step 1: Validate filters
            :ok =
              FilterValidator.validate_filters(WorkloadResource, [
                %{operator: :eq, left: %{name: :email}, right: %{value: "user#{i}@example.com"}}
              ])

            # Step 2: Build query
            {cql, params} =
              QueryBuilder.build_optimized_query(%AshScylla.Query{
                table: "users",
                filters: [
                  %{operator: :eq, left: %{name: :email}, right: %{value: "user#{i}@example.com"}}
                ],
                sorts: [{:name, :asc}],
                limit: 10,
                select: [:id, :name, :email],
                resource: WorkloadResource,
                repo: nil,
                tenant: nil
              })

            # Step 3: Execute within telemetry span
            result =
              Telemetry.span(WorkloadResource, :read, cql, fn ->
                Process.sleep(1)
                {:ok, []}
              end)

            {cql, params, result}
          end)
        end)

      results = Task.await_many(tasks, 30_000)
      assert length(results) == 30

      Enum.each(results, fn {cql, params, result} ->
        assert String.contains?(cql, "SELECT id, name, email FROM users")
        assert String.contains?(cql, "WHERE email = ?")
        # ScyllaDB does not support ORDER BY with secondary index scans;
        # email is a secondary-indexed column, so ORDER BY is stripped
        refute String.contains?(cql, "ORDER BY")
        assert String.contains?(cql, "LIMIT ?")
        # email value + limit
        assert length(params) == 2
        assert result == {:ok, []}
      end)

      messages = collect_telemetry_messages(30, 15_000)
      assert length(messages) == 30

      :telemetry.detach("e2e-stop")
    end

    test "concurrent DSL operations across different resource configurations" do
      tasks = [
        Task.async(fn ->
          Dsl.pagination(WorkloadResource) == :token
        end),
        Task.async(fn ->
          Dsl.per_action_consistency(WorkloadResource)[:read] == :one
        end),
        Task.async(fn ->
          Dsl.has_secondary_index?(WorkloadResource, :email) == true
        end),
        Task.async(fn ->
          Dsl.has_secondary_index?(WorkloadResource, :nonexistent) == false
        end),
        Task.async(fn ->
          Dsl.consistency(WorkloadResource) == :quorum
        end),
        Task.async(fn ->
          Dsl.ttl(WorkloadResource) == 3600
        end)
      ]

      # Run the same checks concurrently many times
      all_tasks = Enum.flat_map(1..10, fn _ -> tasks end)
      results = Task.await_many(all_tasks, 15_000)
      assert length(results) == 60
      assert Enum.all?(results, &(&1 == true))
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp collect_telemetry_messages(expected_count, timeout) do
    collect_telemetry_messages(expected_count, timeout, [])
  end

  defp collect_telemetry_messages(0, _timeout, acc), do: Enum.reverse(acc)

  defp collect_telemetry_messages(remaining, timeout, acc) do
    receive do
      msg ->
        collect_telemetry_messages(remaining - 1, timeout, [msg | acc])
    after
      timeout ->
        Enum.reverse(acc)
    end
  end
end
