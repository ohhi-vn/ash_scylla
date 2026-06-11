# Performance benchmarks for AshScylla
# Measures latency and throughput of query building operations (no database needed)

defmodule AshScylla.Benchmarks.Performance do
  @moduledoc """
  Performance benchmarks for AshScylla query building operations.

  These benchmarks measure the CPU cost of generating CQL queries —
  no database connection is required. All benchmarks use the public
  QueryBuilder API: build_optimized_query/1 and filter_to_cql/1.
  """

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.QueryBuilder

  @table "bench_test"

  def run do
    Benchee.run(
      %{
        # SELECT query building
        "select_all" => fn -> bench_select_all() end,
        "select_with_pk_filter" => fn -> bench_select_with_pk_filter() end,
        "select_with_secondary_index" => fn -> bench_select_with_secondary_index() end,
        "select_with_multiple_filters" => fn -> bench_select_with_multiple_filters() end,
        "select_with_sort_and_limit" => fn -> bench_select_with_sort_and_limit() end,
        "select_with_select_columns" => fn -> bench_select_with_select_columns() end,
        "select_complex" => fn -> bench_select_complex() end,
        # WHERE clause building
        "where_clause_empty" => fn -> bench_where_clause_empty() end,
        "where_clause_single" => fn -> bench_where_clause_single() end,
        "where_clause_multiple" => fn -> bench_where_clause_multiple() end,
        # ORDER BY building
        "order_by_empty" => fn -> bench_order_by_empty() end,
        "order_by_single" => fn -> bench_order_by_single() end,
        "order_by_multiple" => fn -> bench_order_by_multiple() end,
        # Filter-to-CQL conversion
        "filter_eq" => fn -> bench_filter(:eq) end,
        "filter_gt" => fn -> bench_filter(:gt) end,
        "filter_gte" => fn -> bench_filter(:gte) end,
        "filter_lt" => fn -> bench_filter(:lt) end,
        "filter_in" => fn -> bench_filter(:in) end,
        "filter_and" => fn -> bench_filter(:and) end,
        "filter_or" => fn -> bench_filter(:or) end
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

  # ── SELECT query building ────────────────────────────────────────────────

  defp base_query do
    %DataLayer{
      resource: nil,
      repo: nil,
      table: @table,
      filters: [],
      sorts: [],
      limit: nil,
      offset: nil,
      select: nil,
      tenant: nil,
      context: %{}
    }
  end

  defp bench_select_all do
    QueryBuilder.build_optimized_query(base_query())
  end

  defp bench_select_with_pk_filter do
    query = %{
      base_query()
      | filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "some-uuid"}}]
    }

    QueryBuilder.build_optimized_query(query)
  end

  defp bench_select_with_secondary_index do
    query = %{
      base_query()
      | filters: [%{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}}]
    }

    QueryBuilder.build_optimized_query(query)
  end

  defp bench_select_with_multiple_filters do
    query = %{
      base_query()
      | filters: [
          %{operator: :eq, left: %{name: :status}, right: %{value: "active"}},
          %{operator: :>, left: %{name: :age}, right: %{value: 18}}
        ]
    }

    QueryBuilder.build_optimized_query(query)
  end

  defp bench_select_with_sort_and_limit do
    query = %{
      base_query()
      | filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
        sorts: [name: :asc],
        limit: 100
    }

    QueryBuilder.build_optimized_query(query)
  end

  defp bench_select_with_select_columns do
    query = %{
      base_query()
      | filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "some-uuid"}}],
        select: [:id, :name, :email]
    }

    QueryBuilder.build_optimized_query(query)
  end

  defp bench_select_complex do
    query = %{
      base_query()
      | filters: [
          %{operator: :eq, left: %{name: :status}, right: %{value: "active"}},
          %{operator: :>=, left: %{name: :age}, right: %{value: 21}},
          %{operator: :in, left: %{name: :email}, right: %{value: ["a@b.com", "c@d.com"]}}
        ],
        sorts: [name: :asc, age: :desc],
        limit: 50,
        select: [:id, :name, :email]
    }

    QueryBuilder.build_optimized_query(query)
  end

  # ── WHERE clause building ────────────────────────────────────────────────

  defp bench_where_clause_empty do
    QueryBuilder.build_where_clause([])
  end

  defp bench_where_clause_single do
    QueryBuilder.build_where_clause([
      %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
    ])
  end

  defp bench_where_clause_multiple do
    QueryBuilder.build_where_clause([
      %{operator: :eq, left: %{name: :status}, right: %{value: "active"}},
      %{operator: :>, left: %{name: :age}, right: %{value: 18}}
    ])
  end

  # ── ORDER BY building ────────────────────────────────────────────────────

  defp bench_order_by_empty do
    QueryBuilder.build_order_by([])
  end

  defp bench_order_by_single do
    QueryBuilder.build_order_by([name: :asc])
  end

  defp bench_order_by_multiple do
    QueryBuilder.build_order_by([name: :asc, age: :desc])
  end

  # ── Filter-to-CQL conversion ─────────────────────────────────────────────

  defp bench_filter(:eq) do
    QueryBuilder.filter_to_cql(%{
      operator: :eq,
      left: %{name: :status},
      right: %{value: "active"}
    })
  end

  defp bench_filter(:gt) do
    QueryBuilder.filter_to_cql(%{
      operator: :>,
      left: %{name: :age},
      right: %{value: 18}
    })
  end

  defp bench_filter(:gte) do
    QueryBuilder.filter_to_cql(%{
      operator: :>=,
      left: %{name: :age},
      right: %{value: 21}
    })
  end

  defp bench_filter(:lt) do
    QueryBuilder.filter_to_cql(%{
      operator: :<,
      left: %{name: :age},
      right: %{value: 65}
    })
  end

  defp bench_filter(:in) do
    QueryBuilder.filter_to_cql(%{
      operator: :in,
      left: %{name: :id},
      right: %{value: ["uuid-1", "uuid-2", "uuid-3"]}
    })
  end

  defp bench_filter(:and) do
    QueryBuilder.filter_to_cql(%{
      op: :and,
      left: %{operator: :eq, left: %{name: :status}, right: %{value: "active"}},
      right: %{operator: :>, left: %{name: :age}, right: %{value: 18}}
    })
  end

  defp bench_filter(:or) do
    QueryBuilder.filter_to_cql(%{
      op: :or,
      left: %{operator: :eq, left: %{name: :status}, right: %{value: "active"}},
      right: %{operator: :eq, left: %{name: :status}, right: %{value: "pending"}}
    })
  end
end
