defmodule AshScylla.EdgeCasesTest do
  @moduledoc """
  Edge case and boundary tests for AshScylla.
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.{QueryBuilder, Batch, MaterializedView, Pagination}
  alias AshScylla.Migration

  describe "filter_to_cql/1 edge cases" do
    test "unknown map filter returns placeholder" do
      # Raw maps are now treated as parameter values
      assert {"?", [%{foo: :bar}]} = QueryBuilder.filter_to_cql(%{foo: :bar}, %MapSet{}, %{})
    end

    test "nil filter returns placeholder with nil param" do
      # Raw nil is treated as a parameter value with placeholder
      assert {"?", [nil]} = QueryBuilder.filter_to_cql(nil, %MapSet{}, %{})
    end

    test "atom filter returns placeholder" do
      # Raw atoms are now treated as parameter values
      assert {"?", [:x]} = QueryBuilder.filter_to_cql(:x, %MapSet{}, %{})
    end

    test "string filter returns placeholder" do
      # Raw strings are now treated as parameter values
      assert {"?", ["s"]} = QueryBuilder.filter_to_cql("s", %MapSet{}, %{})
    end

    test "boolean filter returns placeholder" do
      assert {"?", [true]} = QueryBuilder.filter_to_cql(true, %MapSet{}, %{})
      assert {"?", [false]} = QueryBuilder.filter_to_cql(false, %MapSet{}, %{})
    end

    test "integer filter returns placeholder" do
      assert {"?", [42]} = QueryBuilder.filter_to_cql(42, %MapSet{}, %{})
    end

    test "float filter returns placeholder" do
      assert {"?", [3.14]} = QueryBuilder.filter_to_cql(3.14, %MapSet{}, %{})
    end

    test "DateTime filter returns placeholder" do
      dt = ~U[2024-06-15 12:30:00Z]
      assert {"?", [^dt]} = QueryBuilder.filter_to_cql(dt, %MapSet{}, %{})
    end

    test "Date filter returns placeholder" do
      d = ~D[2024-06-15]
      assert {"?", [^d]} = QueryBuilder.filter_to_cql(d, %MapSet{}, %{})
    end

    test "Time filter returns placeholder" do
      t = ~T[12:30:00]
      assert {"?", [^t]} = QueryBuilder.filter_to_cql(t, %MapSet{}, %{})
    end

    test "list filter returns placeholder" do
      assert {"?", [["a", "b"]]} = QueryBuilder.filter_to_cql(["a", "b"], %MapSet{}, %{})
    end

    test "tuple filter returns placeholder" do
      assert {"?", [{192, 168, 1, 1}]} =
               QueryBuilder.filter_to_cql({192, 168, 1, 1}, %MapSet{}, %{})
    end

    test "Decimal filter returns placeholder" do
      d = Decimal.new("3.14")
      assert {"?", [^d]} = QueryBuilder.filter_to_cql(d, %MapSet{}, %{})
    end

    test "serialized binary term returns placeholder" do
      serialized = :erlang.term_to_binary(<<1, 2, 3>>)
      assert {"?", [^serialized]} = QueryBuilder.filter_to_cql(serialized, %MapSet{}, %{})
    end

    test "truly unknown term returns error" do
      assert {:error, {:unknown_filter, _}} =
               QueryBuilder.filter_to_cql(self(), %MapSet{}, %{})
    end

    test "empty IN list" do
      filter = %{operator: :in, left: %{name: "s"}, right: %{value: []}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "s IN ()"
      assert params == []
    end

    test "single-value IN" do
      filter = %{operator: :in, left: %{name: "s"}, right: %{value: ["a"]}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "s IN (?)"
      assert params == ["a"]
    end

    test "large IN list (500 values)" do
      values = Enum.map(1..500, &"v#{&1}")
      filter = %{operator: :in, left: %{name: "id"}, right: %{value: values}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert length(params) == 500
    end

    test "unicode values" do
      filter = %{operator: :eq, left: %{name: "n"}, right: %{value: "日本語"}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert params == ["日本語"]
    end

    test "empty string value" do
      filter = %{operator: :eq, left: %{name: "n"}, right: %{value: ""}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert params == [""]
    end

    test "nil value" do
      filter = %{operator: :eq, left: %{name: "n"}, right: %{value: nil}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert params == [nil]
    end

    test "numeric zero" do
      filter = %{operator: :eq, left: %{name: "c"}, right: %{value: 0}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert params == [0]
    end

    test "boolean false" do
      filter = %{operator: :eq, left: %{name: "a"}, right: %{value: false}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert params == [false]
    end

    test "float values" do
      filter = %{operator: :gt, left: %{name: "s"}, right: %{value: 3.14}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert params == [3.14]
    end

    test "negative numbers" do
      filter = %{operator: :lt, left: %{name: "t"}, right: %{value: -273}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert params == [-273]
    end

    test "DateTime values" do
      dt = ~U[2024-06-15 12:30:00Z]
      filter = %{operator: :gte, left: %{name: "c"}, right: %{value: dt}}
      {_cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert params == [dt]
    end

    test "deeply nested AND/OR (3 levels) raises error for cross-field OR" do
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

      # Cross-field OR: (a=1 AND b=2) OR (c=3) — CQL cannot express this
      assert_raise AshScylla.Error, ~r/CQL does not support OR across different fields/, fn ->
        QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      end
    end

    test "unknown operator falls back to =" do
      filter = %{operator: :xyz, left: %{name: "f"}, right: %{value: "v"}}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "f = ?"
      assert params == ["v"]
    end

    test ":not_eq" do
      filter = %{operator: :not_eq, left: %{name: "s"}, right: %{value: "d"}}
      {cql, _params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "s != ?"
    end

    test ":lte" do
      filter = %{operator: :lte, left: %{name: "a"}, right: %{value: 65}}
      {cql, _params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "a <= ?"
    end

    test ":contains" do
      filter = %{operator: :contains, left: %{name: "d"}, right: %{value: "k"}}
      {cql, _params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "d LIKE ?"
    end

    test "bang version raises on unknown" do
      assert_raise ArgumentError, fn ->
        self()
        |> then(&QueryBuilder.filter_to_cql!(&1, %MapSet{}, %{}))
      end
    end

    test "bang version raises on reference" do
      assert_raise ArgumentError, fn ->
        make_ref()
        |> then(&QueryBuilder.filter_to_cql!(&1, %MapSet{}, %{}))
      end
    end

    test "bang version works on valid" do
      filter = %{operator: :eq, left: %{name: "id"}, right: %{value: "a"}}
      {cql, params} = QueryBuilder.filter_to_cql!(filter, %MapSet{}, %{})
      assert cql == "id = ?"
      assert params == ["a"]
    end
  end

  describe "filter_to_cql/1 with raw values (Ash operator format)" do
    test "equality with raw string value" do
      filter = %{operator: :==, left: %{name: "id"}, right: "abc-123"}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "id = ?"
      assert params == ["abc-123"]
    end

    test "equality with raw integer value" do
      filter = %{operator: :==, left: %{name: "count"}, right: 42}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "count = ?"
      assert params == [42]
    end

    test "greater than or equal with raw DateTime" do
      dt = ~U[2025-06-17 00:00:00Z]
      filter = %{operator: :>=, left: %{name: "started_at"}, right: dt}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "started_at >= ?"
      assert params == [dt]
    end

    test "less than or equal with raw DateTime" do
      dt = ~U[2026-06-18 00:00:00Z]
      filter = %{operator: :<=, left: %{name: "started_at"}, right: dt}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "started_at <= ?"
      assert params == [dt]
    end

    test "greater than with raw Date" do
      d = ~D[2025-06-17]
      filter = %{operator: :>, left: %{name: "created_date"}, right: d}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "created_date > ?"
      assert params == [d]
    end

    test "equality with raw float value" do
      filter = %{operator: :==, left: %{name: "score"}, right: 3.14}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "score = ?"
      assert params == [3.14]
    end

    test "equality with raw boolean value" do
      filter = %{operator: :==, left: %{name: "active"}, right: true}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "active = ?"
      assert params == [true]
    end

    test "equality with raw nil value" do
      filter = %{operator: :==, left: %{name: "deleted_at"}, right: nil}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "deleted_at = ?"
      assert params == [nil]
    end

    test "not equal with raw string value" do
      filter = %{operator: :!=, left: %{name: "status"}, right: "deleted"}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "status != ?"
      assert params == ["deleted"]
    end

    test "IN with raw list value" do
      filter = %{operator: :in, left: %{name: "status"}, right: ["active", "pending"]}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "status IN (?, ?)"
      assert params == ["active", "pending"]
    end

    test "IN with MapSet value" do
      filter = %{operator: :in, left: %{name: "status"}, right: MapSet.new(["active", "pending"])}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "status IN (?, ?)"
      assert "active" in params
      assert "pending" in params
    end

    test "is_nil with raw true" do
      filter = %{operator: :is_nil, left: %{name: "deleted_at"}, right: true}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "deleted_at IS NULL"
      assert params == []
    end

    test "is_nil with raw false" do
      filter = %{operator: :is_nil, left: %{name: "deleted_at"}, right: false}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "deleted_at IS NOT NULL"
      assert params == []
    end

    test "starts_with with raw string value" do
      filter = %{operator: :starts_with, left: %{name: "name"}, right: "Jo"}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "name LIKE ?"
      assert params == ["%Jo"]
    end

    test "ends_with with raw string value" do
      filter = %{operator: :ends_with, left: %{name: "email"}, right: ".com"}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "email LIKE ?"
      assert params == [".com%"]
    end

    test "contains with raw string value" do
      filter = %{operator: :contains, left: %{name: "bio"}, right: "elixir"}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "bio LIKE ?"
      assert params == ["%elixir%"]
    end

    test "raw value with unknown operator falls back to =" do
      filter = %{operator: :custom_op, left: %{name: "field"}, right: "val"}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "field = ?"
      assert params == ["val"]
    end
  end

  describe "filter_to_cql/1 with raw DateTime range (issue repro)" do
    test "reproduces the exact issue: uuid equality + datetime range" do
      user_id = "019ed48d-f65a-7c9b-8ab9-a25a17829709"
      start_dt = ~U[2025-06-17 00:00:00Z]
      end_dt = ~U[2026-06-18 00:00:00Z]

      filter = %{
        op: :and,
        left: %{
          op: :and,
          left: %{operator: :==, left: %{name: "user_id"}, right: user_id},
          right: %{operator: :>=, left: %{name: "started_at"}, right: start_dt}
        },
        right: %{operator: :<=, left: %{name: "started_at"}, right: end_dt}
      }

      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})

      assert cql == "user_id = ? AND started_at >= ? AND started_at <= ?"
      assert params == [user_id, start_dt, end_dt]
    end

    test "single datetime equality filter" do
      dt = ~U[2025-06-17 00:00:00Z]
      filter = %{operator: :==, left: %{name: "created_at"}, right: dt}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "created_at = ?"
      assert params == [dt]
    end

    test "datetime range with only gte" do
      dt = ~U[2025-06-17 00:00:00Z]
      filter = %{operator: :>=, left: %{name: "started_at"}, right: dt}
      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "started_at >= ?"
      assert params == [dt]
    end

    test "nested AND with multiple datetime fields" do
      start_dt = ~U[2025-01-01 00:00:00Z]
      end_dt = ~U[2025-12-31 23:59:59Z]

      filter = %{
        op: :and,
        left: %{operator: :>=, left: %{name: "started_at"}, right: start_dt},
        right: %{operator: :<=, left: %{name: "ended_at"}, right: end_dt}
      }

      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "started_at >= ? AND ended_at <= ?"
      assert params == [start_dt, end_dt]
    end
  end

  describe "build_optimized_query/1 with raw value filters (full pipeline)" do
    test "full query with uuid equality + datetime range" do
      start_dt = ~U[2025-06-17 00:00:00Z]
      end_dt = ~U[2026-06-18 00:00:00Z]

      filter = %{
        op: :and,
        left: %{
          op: :and,
          left: %{
            operator: :==,
            left: %{name: "user_id"},
            right: "019ed48d-f65a-7c9b-8ab9-a25a17829709"
          },
          right: %{operator: :>=, left: %{name: "started_at"}, right: start_dt}
        },
        right: %{operator: :<=, left: %{name: "started_at"}, right: end_dt}
      }

      dlq = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "members",
        filters: [filter],
        sorts: [started_at: :desc],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {q, params}} = QueryBuilder.build_optimized_query(dlq)

      assert q ==
               "SELECT * FROM members WHERE user_id = ? AND started_at >= ? AND started_at <= ? ORDER BY started_at desc"

      assert params == ["019ed48d-f65a-7c9b-8ab9-a25a17829709", start_dt, end_dt]

      # Verify parentheses are balanced
      opens = q |> String.graphemes() |> Enum.count(&(&1 == "("))
      closes = q |> String.graphemes() |> Enum.count(&(&1 == ")"))
      assert opens == closes
    end

    test "full query with limit and raw datetime" do
      dt = ~U[2025-06-17 00:00:00Z]

      filter = %{
        op: :and,
        left: %{operator: :==, left: %{name: "status"}, right: "active"},
        right: %{operator: :>=, left: %{name: "created_at"}, right: dt}
      }

      dlq = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "events",
        filters: [filter],
        sorts: [],
        limit: 50,
        select: nil,
        tenant: nil
      }

      {:ok, {q, params}} = QueryBuilder.build_optimized_query(dlq)

      assert q == "SELECT * FROM events WHERE status = ? AND created_at >= ? LIMIT ?"
      assert params == ["active", dt, {"int", 50}]
    end

    test "full query with select columns and raw values" do
      dt = ~U[2025-01-01 00:00:00Z]

      filter = %{operator: :>=, left: %{name: "started_at"}, right: dt}

      dlq = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "games",
        filters: [filter],
        sorts: [started_at: :desc],
        limit: 100,
        select: [:id, :name, :started_at],
        tenant: nil
      }

      {:ok, {q, params}} = QueryBuilder.build_optimized_query(dlq)

      assert q ==
               "SELECT id, name, started_at FROM games WHERE started_at >= ? ORDER BY started_at desc LIMIT ?"

      assert params == [dt, {"int", 100}]
    end

    test "full query with OR and raw values" do
      filter = %{
        op: :or,
        left: %{operator: :==, left: %{name: "status"}, right: "active"},
        right: %{operator: :==, left: %{name: "status"}, right: "pending"}
      }

      dlq = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "tasks",
        filters: [filter],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {q, params}} = QueryBuilder.build_optimized_query(dlq)

      assert q == "SELECT * FROM tasks WHERE status IN (?, ?)"
      assert params == ["active", "pending"]
    end

    test "full query with nested AND/OR and raw values" do
      dt = ~U[2025-06-01 00:00:00Z]

      filter = %{
        op: :and,
        left: %{
          op: :or,
          left: %{operator: :==, left: %{name: "status"}, right: "active"},
          right: %{operator: :==, left: %{name: "status"}, right: "pending"}
        },
        right: %{operator: :>=, left: %{name: "created_at"}, right: dt}
      }

      dlq = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "items",
        filters: [filter],
        sorts: [created_at: :asc],
        limit: 25,
        select: nil,
        tenant: nil
      }

      {:ok, {q, params}} = QueryBuilder.build_optimized_query(dlq)

      assert q ==
               "SELECT * FROM items WHERE status IN (?, ?) AND created_at >= ? ORDER BY created_at asc LIMIT ?"

      assert params == ["active", "pending", dt, {"int", 25}]

      # Verify balanced parens
      opens = q |> String.graphemes() |> Enum.count(&(&1 == "("))
      closes = q |> String.graphemes() |> Enum.count(&(&1 == ")"))
      assert opens == closes
    end

    test "full query with is_nil raw boolean" do
      filter = %{
        op: :and,
        left: %{operator: :==, left: %{name: "status"}, right: "active"},
        right: %{operator: :is_nil, left: %{name: "deleted_at"}, right: true}
      }

      dlq = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "records",
        filters: [filter],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {q, params}} = QueryBuilder.build_optimized_query(dlq)

      assert q == "SELECT * FROM records WHERE status = ? AND deleted_at IS NULL"
      assert params == ["active"]
    end

    test "full query with IN raw list" do
      filter = %{
        op: :and,
        left: %{operator: :in, left: %{name: "status"}, right: ["active", "pending", "archived"]},
        right: %{operator: :>=, left: %{name: "created_at"}, right: ~U[2025-01-01 00:00:00Z]}
      }

      dlq = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "posts",
        filters: [filter],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {q, params}} = QueryBuilder.build_optimized_query(dlq)

      assert q == "SELECT * FROM posts WHERE status IN (?, ?, ?) AND created_at >= ?"
      assert params == ["active", "pending", "archived", ~U[2025-01-01 00:00:00Z]]
    end
  end

  describe "CQL syntax validation" do
    test "parentheses are balanced for deeply nested AND" do
      filter = %{
        op: :and,
        left: %{
          op: :and,
          left: %{
            op: :and,
            left: %{operator: :==, left: %{name: "a"}, right: 1},
            right: %{operator: :==, left: %{name: "b"}, right: 2}
          },
          right: %{operator: :==, left: %{name: "c"}, right: 3}
        },
        right: %{operator: :==, left: %{name: "d"}, right: 4}
      }

      {cql, _} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      opens = cql |> String.graphemes() |> Enum.count(&(&1 == "("))
      closes = cql |> String.graphemes() |> Enum.count(&(&1 == ")"))
      assert opens == closes
    end

    test "parentheses are balanced for mixed AND/OR raises error for cross-field OR" do
      filter = %{
        op: :or,
        left: %{
          op: :and,
          left: %{operator: :==, left: %{name: "a"}, right: 1},
          right: %{operator: :==, left: %{name: "b"}, right: 2}
        },
        right: %{
          op: :and,
          left: %{operator: :==, left: %{name: "c"}, right: 3},
          right: %{operator: :==, left: %{name: "d"}, right: 4}
        }
      }

      # Cross-field OR: (a=1 AND b=2) OR (c=3 AND d=4) — CQL cannot express this
      assert_raise AshScylla.Error, ~r/CQL does not support OR across different fields/, fn ->
        QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      end
    end

    test "no trailing open paren for simple filter" do
      filter = %{operator: :==, left: %{name: "id"}, right: "abc"}
      {cql, _} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      refute String.starts_with?(cql, "(")
      assert cql == "id = ?"
    end

    test "full query has no dangling parens" do
      filter = %{
        op: :and,
        left: %{operator: :>=, left: %{name: "started_at"}, right: ~U[2025-06-17 00:00:00Z]},
        right: %{operator: :<=, left: %{name: "started_at"}, right: ~U[2026-06-18 00:00:00Z]}
      }

      dlq = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [filter],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {q, _}} = QueryBuilder.build_optimized_query(dlq)

      opens = q |> String.graphemes() |> Enum.count(&(&1 == "("))
      closes = q |> String.graphemes() |> Enum.count(&(&1 == ")"))
      assert opens == closes
    end
  end

  describe "build_optimized_query/1 edge cases" do
    test "empty select list" do
      qs = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [],
        sorts: [],
        limit: nil,
        select: [],
        tenant: nil
      }

      {:ok, {cql, _}} = QueryBuilder.build_optimized_query(qs)
      assert cql == "SELECT * FROM t"
    end

    test "single column select" do
      qs = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [],
        sorts: [],
        limit: nil,
        select: [:id],
        tenant: nil
      }

      {:ok, {cql, _}} = QueryBuilder.build_optimized_query(qs)
      assert cql == "SELECT id FROM t"
    end

    test "multiple sort fields" do
      qs = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [],
        sorts: [%{field: :a, direction: :asc}, %{field: :b, direction: :desc}],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _}} = QueryBuilder.build_optimized_query(qs)
      assert String.contains?(cql, "ORDER BY a asc, b desc")
    end

    test "empty filters means no WHERE" do
      qs = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, _}} = QueryBuilder.build_optimized_query(qs)
      refute String.contains?(cql, "WHERE")
    end

    test "filter with expression key" do
      f = %{expression: %{operator: :eq, left: %{name: "s"}, right: %{value: "a"}}}

      qs = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [f],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, params}} = QueryBuilder.build_optimized_query(qs)
      assert String.contains?(cql, "WHERE")
      assert params == ["a"]
    end

    test "filter params before limit params" do
      f = %{operator: :eq, left: %{name: "s"}, right: %{value: "a"}}

      qs = %AshScylla.Query{
        resource: nil,
        repo: nil,
        table: "t",
        filters: [f],
        sorts: [],
        limit: 25,
        select: nil,
        tenant: nil
      }

      {:ok, {cql, params}} = QueryBuilder.build_optimized_query(qs)
      assert cql == "SELECT * FROM t WHERE s = ? LIMIT ?"
      assert params == ["a", {"int", 25}]
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
      {:ok, {c, p}} = QueryBuilder.build_where_clause([], %MapSet{}, %{})
      assert c == ""
      assert p == []
    end

    test "single filter" do
      f = %{operator: :eq, left: %{name: "id"}, right: %{value: "a"}}
      {:ok, {c, p}} = QueryBuilder.build_where_clause([f], %MapSet{}, %{})
      assert c == "id = ?"
      assert p == ["a"]
    end

    test "multiple filters joined with AND" do
      fs = [
        %{operator: :eq, left: %{name: "s"}, right: %{value: "a"}},
        %{operator: :gt, left: %{name: "age"}, right: %{value: 18}},
        %{operator: :lt, left: %{name: "age"}, right: %{value: 65}}
      ]

      {:ok, {c, p}} = QueryBuilder.build_where_clause(fs, %MapSet{}, %{})
      assert c == "s = ? AND age > ? AND age < ?"
      assert p == ["a", 18, 65]
    end

    test "skips truly invalid filter" do
      result = QueryBuilder.build_where_clause([:bad], %MapSet{}, %{})
      assert is_tuple(result)
    end

    test "raw string filter produces placeholder clause" do
      {:ok, {clause, params}} =
        QueryBuilder.build_where_clause(["5f76eab7-be8b-4a47-9d97-c36f6e42db0f"], %MapSet{}, %{})

      assert clause == "?"
      assert params == ["5f76eab7-be8b-4a47-9d97-c36f6e42db0f"]
    end

    test "raw atom filter produces placeholder clause" do
      {:ok, {clause, params}} = QueryBuilder.build_where_clause([:invalid_atom], %MapSet{}, %{})
      assert clause == "?"
      assert params == [:invalid_atom]
    end

    test "raw nil filter produces placeholder clause" do
      {:ok, {clause, params}} = QueryBuilder.build_where_clause([nil], %MapSet{}, %{})
      assert clause == "?"
      assert params == [nil]
    end

    test "raw integer filter produces placeholder clause" do
      {:ok, {clause, params}} = QueryBuilder.build_where_clause([42], %MapSet{}, %{})
      assert clause == "?"
      assert params == [42]
    end

    test "valid filters still work when mixed with raw values" do
      filters = [
        :invalid,
        %{operator: :eq, left: %{name: :status}, right: %{value: "active"}},
        "bad_string",
        %{operator: :gt, left: %{name: :age}, right: %{value: 18}}
      ]

      {:ok, {clause, params}} = QueryBuilder.build_where_clause(filters, %MapSet{}, %{})
      assert clause =~ "status"
      assert clause =~ "age"
      assert "active" in params
      assert 18 in params
    end

    test "all raw value filters produce placeholder clauses" do
      {:ok, {clause, params}} =
        QueryBuilder.build_where_clause([:a, :b, "c", nil, 42], %MapSet{}, %{})

      assert clause != ""
      assert is_list(params)
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
      {:ok, {c, p}} = Pagination.build_paginated_query("t", %{}, nil, 10)
      assert c == "SELECT * FROM t LIMIT ?"
      assert p == [10]
    end

    test "with token" do
      {:ok, {c, p}} = Pagination.build_paginated_query("t", %{}, "tok", 25)
      assert c == "SELECT * FROM t WHERE token() > ? LIMIT ?"
      assert p == ["tok", 25]
    end

    test "page_size 1" do
      {:ok, {_, p}} = Pagination.build_paginated_query("t", %{}, nil, 1)
      assert p == [1]
    end

    test "large page_size" do
      {:ok, {_, p}} = Pagination.build_paginated_query("t", %{}, nil, 10_000)
      assert p == [1000]
    end

    test "non-empty filter is converted to CQL" do
      {:ok, {q, p}} = Pagination.build_paginated_query("t", %{s: "a"}, nil, 10)
      assert String.contains?(q, "s = ?")
      assert p == ["a", 10]
    end
  end

  describe "MaterializedView edge cases" do
    test "single partition key" do
      cql = MaterializedView.create_view_cql("v", "t", primary_key: [:id], include_columns: [:n])
      assert String.contains?(cql, "PRIMARY KEY (\"id\")")
      refute String.contains?(cql, "CLUSTERING ORDER")
    end

    test "many clustering keys" do
      cql =
        MaterializedView.create_view_cql("v", "t",
          primary_key: [:pk, :c1, :c2, :c3],
          include_columns: [:d]
        )

      assert String.contains?(cql, "PRIMARY KEY ((\"pk\"), \"c1\", \"c2\", \"c3\")")
    end

    test "empty include_columns" do
      cql = MaterializedView.create_view_cql("v", "t", primary_key: [:e, :id])
      assert String.contains?(cql, "SELECT \"e\", \"id\"")
    end

    test "multiple clustering order" do
      cql =
        MaterializedView.create_view_cql("v", "t",
          primary_key: [:pk, :c1, :c2],
          clustering_order: [c1: :asc, c2: :desc]
        )

      assert String.contains?(cql, "CLUSTERING ORDER BY (\"c1\" asc, \"c2\" desc)")
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
      assert String.contains?(hd(result), "ON \"u\"")
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
      assert length(result) == 2
      assert String.contains?(hd(result), ~s/("fn")/)
      assert String.contains?(Enum.at(result, 1), ~s/("ln")/)
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
        :limit,
        :select,
        :multitenancy,
        :bulk_create,
        :keyset,
        :upsert,
        :boolean_filter,
        :distinct,
        {:atomic, :update},
        {:atomic, :upsert},
        {:aggregate, :count}
      ]

      for f <- supported, do: assert(DataLayer.can?(nil, f) == true)
    end

    test "can? false for all unsupported" do
      unsupported = [
        :aggregate,
        :join,
        :lateral_join,
        :lock,
        :combine,
        :offset
      ]

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

  # ============================================================================
  # Ash 3.0+ Edge Case Tests
  # ============================================================================

  describe "Ash.Resource.Info edge cases" do
    test "TestResource domain is TestDomain" do
      assert Ash.Resource.Info.domain(AshScylla.TestResource) == AshScylla.TestDomain
    end

    test "TestResource primary key is id" do
      assert :id in Ash.Resource.Info.primary_key(AshScylla.TestResource)
    end

    test "TestResource has expected attributes" do
      names = Ash.Resource.Info.attributes(AshScylla.TestResource) |> Enum.map(& &1.name)
      assert :id in names
      assert :name in names
      assert :email in names
      assert :age in names
      assert :password_hash in names
      assert :org_id in names
      assert :created_at in names
      assert :updated_at in names
    end

    test "TestResource password_hash is not public" do
      attr = Ash.Resource.Info.attribute(AshScylla.TestResource, :password_hash)
      assert attr.public? == false
    end

    test "TestResource name is public" do
      attr = Ash.Resource.Info.attribute(AshScylla.TestResource, :name)
      assert attr.public? == true
    end

    test "TestResource has code interface functions" do
      interfaces = Ash.Resource.Info.interfaces(AshScylla.TestResource)
      names = Enum.map(interfaces, & &1.name)
      assert :create in names
      assert :read in names
    end

    test "TestResourceWithIndexes has correct table" do
      assert AshScylla.DataLayer.Dsl.table(AshScylla.TestResourceWithIndexes) == "test_users"
    end

    test "TestResourceWithIndexes has 3 secondary indexes" do
      indexes = AshScylla.DataLayer.Dsl.secondary_indexes(AshScylla.TestResourceWithIndexes)
      assert length(indexes) == 3
    end
  end
end
