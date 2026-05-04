# Performance benchmarks for AshScylla
# Measures latency, throughput for individual operations

defmodule AshScylla.Benchmarks.Performance do
  @moduledoc """
  Performance benchmarks for AshScylla operations.

  Measures:
  - Single record CRUD operations latency
  - Query performance with different filter types
  - Batch operation throughput
  - Secondary index query performance
  """

  alias AshScylla.DataLayer.QueryBuilder
  alias AshScylla.DataLayer.Batch

  # Mock resource for benchmarking
  defmodule TestResource do
    use Ash.Resource,
      data_layer: AshScylla.DataLayer

    ash_scylla do
      table "bench_test"
      keyspace "bench_keyspace"
      consistency :quorum
      secondary_index :email
      secondary_index :status
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string
      attribute :email, :string
      attribute :status, :string
      attribute :age, :integer
      attribute :inserted_at, :utc_datetime
    end
  end

  def run do
    Benchee.run(
      %{
        "single_insert" => fn -> bench_single_insert() end,
        "single_read_by_pk" => fn -> bench_single_read_by_pk() end,
        "single_update" => fn -> bench_single_update() end,
        "single_delete" => fn -> bench_single_delete() end,
        "query_with_pk" => fn -> bench_query_with_pk() end,
        "query_with_secondary_index" => fn -> bench_query_with_secondary_index() end,
        "query_with_filter" => fn -> bench_query_with_filter() end,
        "build_simple_query" => fn -> bench_build_simple_query() end,
        "build_complex_query" => fn -> bench_build_complex_query() end,
        "batch_insert_10" => fn -> bench_batch_insert(10) end,
        "batch_insert_100" => fn -> bench_batch_insert(100) end,
        "batch_insert_1000" => fn -> bench_batch_insert(1000) end
      },
      time: 10,
      memory_time: 2,
      reduction_time: 2,
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.HTML, file: "benchmarks/results/performance.html"}
      ]
    )
  end

  defp bench_single_insert do
    changeset =
      TestResource
      |> Ash.Changeset.for_create(:create, %{
        name: "Test User",
        email: "test@example.com",
        status: "active",
        age: 30,
        inserted_at: DateTime.utc_now()
      })

    # Simulate the query building part (since we don't have a real repo)
    QueryBuilder.build_insert(TestResource, changeset)
  end

  defp bench_single_read_by_pk do
    QueryBuilder.build_select(TestResource, [id: "some-uuid"])
  end

  defp bench_single_update do
    changeset =
      TestResource
      |> Ash.Changeset.for_update(:update, %{name: "Updated Name"})

    QueryBuilder.build_update(TestResource, changeset, [id: "some-uuid"])
  end

  defp bench_single_delete do
    QueryBuilder.build_delete(TestResource, [id: "some-uuid"])
  end

  defp bench_query_with_pk do
    QueryBuilder.build_optimized_query(
      TestResource,
      filter: [id: "some-uuid"]
    )
  end

  defp bench_query_with_secondary_index do
    QueryBuilder.build_optimized_query(
      TestResource,
      filter: [email: "test@example.com"]
    )
  end

  defp bench_query_with_filter do
    filter = %Ash.Filter{
      resource: TestResource,
      expression: %Ash.Filter.Predicate{
        left: %{attribute: :age, resource: TestResource},
        operator: :>,
        right: 18
      }
    }

    QueryBuilder.filter_to_cql(filter)
  end

  defp bench_build_simple_query do
    QueryBuilder.build_select(TestResource)
  end

  defp bench_build_complex_query do
    QueryBuilder.build_optimized_query(
      TestResource,
      filter: [status: "active", age: 30],
      sort: [name: :asc],
      limit: 100
    )
  end

  defp bench_batch_insert(count) do
    records =
      Enum.map(1..count, fn i ->
        %{
          id: "uuid-#{i}",
          name: "User #{i}",
          email: "user#{i}@example.com",
          status: "active",
          age: 20 + rem(i, 50)
        }
      end)

    Batch.batch_insert(TestResource, records)
  end
end
