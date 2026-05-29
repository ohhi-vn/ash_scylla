defmodule AshScylla.EdgeCasesTest do
  @moduledoc """
  Edge case and boundary tests for AshScylla.
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.{QueryBuilder, Batch, MaterializedView, Pagination}
  alias AshScylla.Migration

  describe "filter_to_cql/1 edge cases" do
    test "unknown map filter returns error" do
      assert {:error, {:unknown_filter, %{foo: :bar}}} = QueryBuilder.filter_to_cql(%{foo: :bar})
    end

    test "nil filter returns error" do
      assert {:error, {:unknown_filter, nil}} = QueryBuilder.filter_to_cql(nil)
    end

    test "atom filter returns error" do
      assert {:error, {:unknown_filter, :x}} = QueryBuilder.filter_to_cql(:x)
    end

    test "string filter returns error" do
      assert {:error, {:unknown_filter, "s"}} = QueryBuilder.filter_to_cql("s")
    end

    test "empty IN list" do
      filter = %{operator: :in, left: %{name: "s"}, right: %{value: []}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql == "s IN ()"
      assert params == []
    end

    test "single-value IN" do
      filter = %{operator: :in, left: %{name: "s"}, right: %{value: ["a"]}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql == "s IN (?)"
      assert params == ["a"]
    end

    test "large IN list (500 values)" do
      values = Enum.map(1..500, &"v#{&1}")
      filter = %{operator: :in, left: %{name: "id"}, right: %{value: values}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter)
      assert length(params) == 500
    end

    test "unicode values" do
      filter = %{operator: :eq, left: %{name: "n"}, right: %{value: "日本語"}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter)
      assert params == ["日本語"]
    end

    test "empty string value" do
      filter = %{operator: :eq, left: %{name: "n"}, right: %{value: ""}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter)
      assert params == [""]
    end

    test "nil value" do
      filter = %{operator: :eq, left: %{name: "n"}, right: %{value: nil}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter)
      assert params == [nil]
    end

    test "numeric zero" do
      filter = %{operator: :eq, left: %{name: "c"}, right: %{value: 0}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter)
      assert params == [0]
    end

    test "boolean false" do
      filter = %{operator: :eq, left: %{name: "a"}, right: %{value: false}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter)
      assert params == [false]
    end

    test "float values" do
      filter = %{operator: :gt, left: %{name: "s"}, right: %{value: 3.14}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter)
      assert params == [3.14]
    end

    test "negative numbers" do
      filter = %{operator: :lt, left: %{name: "t"}, right: %{value: -273}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter)
      assert params == [-273]
    end

    test "DateTime values" do
      dt = ~U[2024-06-15 12:30:00Z]
      filter = %{operator: :gte, left: %{name: "c"}, right: %{value: dt}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter)
      assert params == [dt]
    end

    test "deeply nested AND/OR (3 levels)" do
      filter = %{
        op: :and,
        left: %{
          op: :or,
          left: %{
            op: :and,
            left: %{operator: :eq, left: %{name: "a"}, right: %{value: 1}},
            right: %{operator: :eq, left: %{name: "b"}, right: %{value: 2}}
          },
          right: %{operator: :eq, left: %{name: "c"}, right: %{value: 3}}
        },
        right: %{operator: :eq, left: %{name: "d"}, right: %{value: 4}}
      }

      {_cql, params} = QueryBuilder.filter_to_cql(filter)
      assert params == [1, 2, 3, 4]
    end

    test "unknown operator falls back to =" do
      filter = %{operator: :xyz, left: %{name: "f"}, right: %{value: "v"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter)
      assert cql == "f = ?"
      assert params == ["v"]
    end

    test ":not_eq" do
      filter = %{operator: :not_eq, left: %{name: "s"}, right: %{value: "d"}}
      {cql, _params} = QueryBuilder.filter_to_cql(filter)
      assert cql == "s != ?"
    end

    test ":lte" do
      filter = %{operator: :lte, left: %{name: "a"}, right: %{value: 65}}
      {cql, _params} = QueryBuilder.filter_to_cql(filter)
      assert cql == "a <= ?"
    end

    test ":contains" do
      filter = %{operator: :contains, left: %{name: "d"}, right: %{value: "k"}}
      {cql, _params} = QueryBuilder.filter_to_cql(filter)
      assert cql == "d LIKE ?"
    end

    test "bang version raises on unknown" do
      assert_raise ArgumentError, fn ->
        QueryBuilder.filter_to_cql!(:bad)
      end
    end

    test "bang version works on valid" do
      filter = %{operator: :eq, left: %{name: "id"}, right: %{value: "a"}}
      {cql, params} = QueryBuilder.filter_to_cql!(filter)
      assert cql == "id = ?"
      assert params == ["a"]
    end
  end

  describe "build_optimized_query/1 edge cases" do
    test "empty select list" do
      qs = %DataLayer{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [],
        tenant: nil
      }

      {cql, _} = QueryBuilder.build_optimized_query(qs)
      assert cql == "SELECT * FROM t"
    end

    test "single column select" do
      qs = %DataLayer{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [:id],
        tenant: nil
      }

      {cql, _} = QueryBuilder.build_optimized_query(qs)
      assert cql == "SELECT id FROM t"
    end

    test "offset is ignored" do
      qs = %DataLayer{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [],
        sorts: [],
        limit: 10,
        offset: 100,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(qs)
      refute String.contains?(cql, "OFFSET")
      assert params == [10]
    end

    test "multiple sort fields" do
      qs = %DataLayer{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [],
        sorts: [%{field: :a, direction: :asc}, %{field: :b, direction: :desc}],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, _} = QueryBuilder.build_optimized_query(qs)
      assert String.contains?(cql, "ORDER BY a asc, b desc")
    end

    test "empty filters means no WHERE" do
      qs = %DataLayer{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, _} = QueryBuilder.build_optimized_query(qs)
      refute String.contains?(cql, "WHERE")
    end

    test "filter with expression key" do
      f = %{expression: %{operator: :eq, left: %{name: "s"}, right: %{value: "a"}}}

      qs = %DataLayer{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [f],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(qs)
      assert String.contains?(cql, "WHERE")
      assert params == ["a"]
    end

    test "filter params before limit params" do
      f = %{operator: :eq, left: %{name: "s"}, right: %{value: "a"}}

      qs = %DataLayer{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [f],
        sorts: [],
        limit: 25,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(qs)
      assert cql == "SELECT * FROM t WHERE s = ? LIMIT ?"
      assert params == ["a", 25]
    end
  end

  describe "build_order_by/1 edge cases" do
    test "tuple format" do
      {c, _} = QueryBuilder.build_order_by([{:n, :asc}])
      assert c == "n asc"
    end

    test "bare atom defaults to ASC" do
      {c, _} = QueryBuilder.build_order_by([{:n}])
      assert c == "n ASC"
    end

    test "map with only field defaults to ASC" do
      {c, _} = QueryBuilder.build_order_by([%{field: :c}])
      assert c == "c ASC"
    end

    test "skips invalid items" do
      {c, _} =
        QueryBuilder.build_order_by([
          %{field: :a, direction: :asc},
          "bad",
          %{field: :b, direction: :desc}
        ])

      assert c == "a asc, b desc"
    end

    test "empty list" do
      {c, p} = QueryBuilder.build_order_by([])
      assert c == ""
      assert p == []
    end

    test "mixed formats" do
      {c, _} = QueryBuilder.build_order_by([%{field: :a, direction: :asc}, {:b, :desc}])
      assert c == "a asc, b desc"
    end
  end

  describe "can_use_secondary_index?/2 edge cases" do
    test "empty filters" do
      defmodule EFR2 do
        def __ash_scylla__(:secondary_indexes), do: [%{columns: [:e], name: nil, options: []}]
        def __ash_scylla__(_), do: nil
      end

      assert {:error, :no_filters} = QueryBuilder.can_use_secondary_index?(EFR2, [])
    end

    test "no indexes at all" do
      defmodule NIR2 do
        def __ash_scylla__(:secondary_indexes), do: []
        def __ash_scylla__(_), do: nil
      end

      fs = [%{operator: :eq, left: %{name: :e}, right: %{value: "x"}}]
      assert {:error, {:missing_indexes, [:e]}} = QueryBuilder.can_use_secondary_index?(NIR2, fs)
    end

    test "partial index coverage" do
      defmodule PIR2 do
        def __ash_scylla__(:secondary_indexes), do: [%{columns: [:e], name: nil, options: []}]
        def __ash_scylla__(_), do: nil
      end

      fs = [
        %{operator: :eq, left: %{name: :e}, right: %{value: "x"}},
        %{operator: :eq, left: %{name: :p}, right: %{value: "y"}}
      ]

      assert {:error, {:missing_indexes, [:p]}} = QueryBuilder.can_use_secondary_index?(PIR2, fs)
    end

    test "all filters indexed" do
      defmodule FIR2 do
        def __ash_scylla__(:secondary_indexes),
          do: [%{columns: [:e], name: nil, options: []}, %{columns: [:p], name: nil, options: []}]

        def __ash_scylla__(_), do: nil
      end

      fs = [
        %{operator: :eq, left: %{name: :e}, right: %{value: "x"}},
        %{operator: :eq, left: %{name: :p}, right: %{value: "y"}}
      ]

      assert {:ok, cols} = QueryBuilder.can_use_secondary_index?(FIR2, fs)
      assert :e in cols
      assert :p in cols
    end
  end

  describe "build_where_clause/1 edge cases" do
    test "empty list" do
      {c, p} = QueryBuilder.build_where_clause([])
      assert c == ""
      assert p == []
    end

    test "single filter" do
      f = %{operator: :eq, left: %{name: "id"}, right: %{value: "a"}}
      {c, p} = QueryBuilder.build_where_clause([f])
      assert c == "id = ?"
      assert p == ["a"]
    end

    test "multiple filters joined with AND" do
      fs = [
        %{operator: :eq, left: %{name: "s"}, right: %{value: "a"}},
        %{operator: :gt, left: %{name: "age"}, right: %{value: 18}},
        %{operator: :lt, left: %{name: "age"}, right: %{value: 65}}
      ]

      {c, p} = QueryBuilder.build_where_clause(fs)
      assert c == "s = ? AND age > ? AND age < ?"
      assert p == ["a", 18, 65]
    end

    test "raises on invalid filter" do
      assert_raise ArgumentError, fn ->
        QueryBuilder.build_where_clause([:bad])
      end
    end
  end

  describe "Batch edge cases" do
    test "empty list returns ok for all" do
      assert {:ok, []} = Batch.batch_insert(nil, [])
      assert {:ok, []} = Batch.batch_update(nil, [])
      assert {:ok, []} = Batch.batch_delete(nil, [])
    end

    test "raises on atom statement" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_insert(nil, [:bad])
      end
    end

    test "raises on 1-tuple" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_insert(nil, [{"q"}])
      end
    end

    test "raises on non-binary query" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_insert(nil, [{123, []}])
      end
    end

    test "raises on non-list params" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_insert(nil, [{"q", "bad"}])
      end
    end

    test "raises on nil statement" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_insert(nil, [nil])
      end
    end

    test "raises on 3-tuple" do
      assert_raise ArgumentError, ~r/Invalid batch statement/, fn ->
        Batch.batch_insert(nil, [{"q", [], :x}])
      end
    end
  end

  describe "Pagination edge cases" do
    test "empty filters no token" do
      {c, p} = Pagination.build_paginated_query("t", %{}, nil, 10)
      assert c == "SELECT * FROM t LIMIT ?"
      assert p == [10]
    end

    test "with token" do
      {c, p} = Pagination.build_paginated_query("t", %{}, "tok", 25)
      assert c == "SELECT * FROM t AND token() > ? LIMIT ?"
      assert p == ["tok", 25]
    end

    test "page_size 1" do
      {_, p} = Pagination.build_paginated_query("t", %{}, nil, 1)
      assert p == [1]
    end

    test "large page_size" do
      {_, p} = Pagination.build_paginated_query("t", %{}, nil, 10_000)
      assert p == [10_000]
    end

    test "non-empty filter is converted to CQL" do
      {q, p} = Pagination.build_paginated_query("t", %{s: "a"}, nil, 10)
      assert String.contains?(q, "s = ?")
      assert p == ["a", 10]
    end
  end

  describe "MaterializedView edge cases" do
    test "single partition key" do
      cql = MaterializedView.create_view_cql("v", "t", primary_key: [:id], include_columns: [:n])
      assert String.contains?(cql, "PRIMARY KEY (id)")
      refute String.contains?(cql, "CLUSTERING ORDER")
    end

    test "many clustering keys" do
      cql =
        MaterializedView.create_view_cql("v", "t",
          primary_key: [:pk, :c1, :c2, :c3],
          include_columns: [:d]
        )

      assert String.contains?(cql, "PRIMARY KEY (pk, c1, c2, c3)")
    end

    test "empty include_columns" do
      cql = MaterializedView.create_view_cql("v", "t", primary_key: [:e, :id])
      assert String.contains?(cql, "SELECT e, id")
    end

    test "multiple clustering order" do
      cql =
        MaterializedView.create_view_cql("v", "t",
          primary_key: [:pk, :c1, :c2],
          clustering_order: [c1: :asc, c2: :desc]
        )

      assert String.contains?(cql, "CLUSTERING ORDER BY (c1 asc, c2 desc)")
    end

    test "deduplicates columns" do
      cql =
        MaterializedView.create_view_cql("v", "t",
          primary_key: [:e, :id],
          include_columns: [:e, :id, :n]
        )

      select_part =
        cql |> String.split("SELECT ") |> List.last() |> String.split(" FROM") |> List.last()

      cols = select_part |> String.split(", ") |> Enum.map(&String.trim/1)
      assert length(cols) == length(Enum.uniq(cols))
    end

    test "custom WHERE clause" do
      cql =
        MaterializedView.create_view_cql("v", "t",
          primary_key: [:e, :id],
          where_clause: "e IS NOT NULL AND active = true"
        )

      assert String.contains?(cql, "WHERE e IS NOT NULL AND active = true")
    end

    test "validate rejects missing pk" do
      assert {:error, "primary_key is required for materialized view"} =
               MaterializedView.validate_view_config(include_columns: [:n])
    end

    test "validate rejects empty pk" do
      assert {:error, "primary_key cannot be empty"} =
               MaterializedView.validate_view_config(primary_key: [])
    end

    test "validate rejects duplicates" do
      assert {:error, "duplicate columns in materialized view definition"} =
               MaterializedView.validate_view_config(primary_key: [:id], include_columns: [:id])
    end

    test "validate accepts valid" do
      assert :ok =
               MaterializedView.validate_view_config(
                 primary_key: [:e, :id],
                 include_columns: [:n, :a]
               )
    end

    test "validate with no include_columns" do
      assert :ok = MaterializedView.validate_view_config(primary_key: [:e, :id])
    end

    test "drop_view_cql" do
      assert "DROP MATERIALIZED VIEW IF EXISTS v" = MaterializedView.drop_view_cql("v")
    end
  end

  describe "Migration edge cases" do
    test "create_type with no fields" do
      cql = Migration.create_type("empty", do: [])
      assert String.contains?(cql, "CREATE TYPE IF NOT EXISTS empty")
    end

    test "create_type with single field" do
      cql = Migration.create_type("s", do: [name: {:text, []}])
      assert String.contains?(cql, "name TEXT")
    end

    test "create_type with many fields" do
      fields = Enum.map(1..50, &{String.to_atom("f#{&1}"), {:text, []}})
      cql = Migration.create_type("wide", do: fields)
      assert String.contains?(cql, "f1 TEXT")
      assert String.contains?(cql, "f50 TEXT")
    end

    test "drop_type" do
      assert "DROP TYPE IF EXISTS t" = Migration.drop_type("t")
    end

    test "create_secondary_indexes_cql for resource without DSL" do
      defmodule NDR2 do
      end

      assert [] = Migration.create_secondary_indexes_cql(NDR2)
    end

    test "create_secondary_indexes_cql with single index" do
      defmodule SIR2 do
        def __ash_scylla__(:secondary_indexes), do: [%{columns: [:e], name: nil, options: []}]
        def __ash_scylla__(:table), do: "u"
        def __ash_scylla__(_), do: nil
      end

      result = Migration.create_secondary_indexes_cql(SIR2)
      assert length(result) == 1
      assert String.contains?(hd(result), "ON u")
    end

    test "create_secondary_indexes_cql with named index" do
      defmodule NmIR2 do
        def __ash_scylla__(:secondary_indexes),
          do: [%{columns: [:e], name: "idx_custom", options: []}]

        def __ash_scylla__(:table), do: "u"
        def __ash_scylla__(_), do: nil
      end

      result = Migration.create_secondary_indexes_cql(NmIR2)
      assert String.contains?(hd(result), "idx_custom")
    end

    test "create_secondary_indexes_cql with multi-column index" do
      defmodule MCIR2 do
        def __ash_scylla__(:secondary_indexes),
          do: [%{columns: [:fn, :ln], name: nil, options: []}]

        def __ash_scylla__(:table), do: "u"
        def __ash_scylla__(_), do: nil
      end

      result = Migration.create_secondary_indexes_cql(MCIR2)
      assert String.contains?(hd(result), "(fn, ln)")
    end

    test "create_secondary_indexes_cql with multiple indexes" do
      defmodule MIR2 do
        def __ash_scylla__(:secondary_indexes),
          do: [
            %{columns: [:e], name: nil, options: []},
            %{columns: [:s], name: nil, options: []},
            %{columns: [:c], name: "idx_c", options: []}

          ]

        def __ash_scylla__(:table), do: "ev"
        def __ash_scylla__(_), do: nil
      end

      result = Migration.create_secondary_indexes_cql(MIR2)
      assert length(result) == 3
    end

    test "drop_secondary_index_cql" do

      assert "DROP INDEX IF EXISTS idx" = Migration.drop_secondary_index_cql(nil, "idx")
    end

    test "keyspace returns nil" do
      assert Migration.keyspace(nil) == nil
    end
  end

  describe "DataLayer edge cases" do
    test "can? with nil feature" do
      assert DataLayer.can?(nil, nil) == false
    end

    test "can? with string feature" do
      assert DataLayer.can?(nil, "create") == false
    end

    test "can? with unsupported tuple" do
      assert DataLayer.can?(nil, {:calculate, :foo}) == false
      assert DataLayer.can?(nil, {:combine, :bar}) == false
    end

    test "can? true for all supported" do
      supported = [
        :create,
        :read,
        :update,
        :destroy,
        :filter,
        :sort,
        :limit,
        :offset,
        :select,
        :multitenancy,
        :bulk_create
      ]

      for f <- supported, do: assert(DataLayer.can?(nil, f) == true)
    end

    test "can? false for all unsupported" do
      unsupported = [:transact, :aggregate, :join, :lateral_join, :lock, :calculate, :combine]
      for f <- unsupported, do: assert(DataLayer.can?(nil, f) == false)
    end
  end

  describe "ScyllaError struct defaults" do
    test "all fields default to nil" do
      e = %AshScylla.Error.ScyllaError{}
      assert e.type == nil
      assert e.reason == nil
      assert e.message == nil
      assert e.suggestion == nil
      assert e.query == nil
      assert e.original_error == nil
    end

    test "partial construction" do
      e = %AshScylla.Error.ScyllaError{type: :timeout, message: "t"}
      assert e.type == :timeout
      assert e.message == "t"
      assert e.suggestion == nil
    end
  end
end
