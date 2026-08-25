defmodule AshScylla.DataLayer.QueryBuilderCoverageTest do
  @moduledoc """
  Line-coverage tests for AshScylla.DataLayer.QueryBuilder paths not exercised
  by query_builder_test.exs: arity-1 wrappers, Ash struct dispatch, raw-value
  operator branches, token clauses, OR-to-IN rewrite shapes, and error paths.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.QueryBuilder

  defmodule QbmIdxResource do
    @moduledoc false
    def __ash_scylla__(:secondary_indexes),
      do: [
        %{columns: [:email], name: nil, options: []},
        %{columns: [:name], name: nil, options: []}
      ]

    def __ash_scylla__(:table), do: "qbm_idx"
    def __ash_scylla__(:keyspace), do: "qbm_ks"
    def __ash_scylla__(_), do: nil
  end

  describe "build_where_clause wrappers" do
    test "arity-1 build_where_clause/1 defaults uuid fields and cql types" do
      filter = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
      assert {:ok, {"status = ?", ["active"]}} = QueryBuilder.build_where_clause([filter])
    end

    test "build_where_clause/3 accepts a map (MapSet) of filters" do
      f1 = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
      f2 = %{operator: :gt, left: %{name: "age"}, right: %{value: 18}}

      assert {:ok, {cql, params}} =
               QueryBuilder.build_where_clause(MapSet.new([f1, f2]), %MapSet{}, %{})

      assert cql in ["age > ? AND status = ?", "status = ? AND age > ?"]
      assert Enum.sort(params) == [18, "active"]
    end
  end

  describe "Ash struct dispatch" do
    test "Operator.In struct converts to IN clause" do
      filter =
        struct(Ash.Query.Operator.In, left: %{name: :status}, right: ["active", "pending"])

      assert {"status IN (?, ?)", ["active", "pending"]} =
               QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "Ash.Query.Call struct with operator?: true converts operator name" do
      filter =
        struct(Ash.Query.Call,
          name: :>=,
          args: [%{name: :age}, %{value: 21}],
          operator?: true
        )

      assert {"age >= ?", [21]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "__function__? starts_with struct produces LIKE with prefix wildcard" do
      filter = %{
        __function__?: true,
        name: :starts_with,
        arguments: [%{name: "name"}, %{value: "Jo"}]
      }

      assert {"name LIKE ?", ["%Jo"]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "__function__? ends_with struct produces LIKE with suffix wildcard" do
      filter = %{
        __function__?: true,
        name: :ends_with,
        arguments: [%{name: "email"}, %{value: ".com"}]
      }

      assert {"email LIKE ?", [".com%"]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "__function__? contains struct produces LIKE with both wildcards" do
      filter = %{
        __function__?: true,
        name: :contains,
        arguments: [%{name: "bio"}, %{value: "elixir"}]
      }

      assert {"bio LIKE ?", ["%elixir%"]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "starts_with unwraps Ash.CiString values before wrapping with wildcards" do
      filter = %{
        operator: :starts_with,
        left: %{name: :name},
        right: %{value: %Ash.CiString{string: "jo"}}
      }

      assert {"name LIKE ?", ["%jo"]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "fragment with a bare argument inspects it into the CQL string" do
      filter = %{
        __function__?: true,
        name: :fragment,
        arguments: [{:raw, "x = "}, {:expr, 1}, :bare]
      }

      assert {"x = ?:bare", [1]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "Overlaps struct with list right side takes the single-value path" do
      filter = struct(Ash.Query.Operator.Overlaps, left: %{name: :tags}, right: ["admin"])
      assert {"tags CONTAINS ?", ["admin"]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "Overlaps struct with non-list non-mapset right side returns FALSE" do
      filter = struct(Ash.Query.Operator.Overlaps, left: %{name: :tags}, right: "admin")
      assert {"FALSE", []} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "Ash.Filter struct unwraps to its expression" do
      filter =
        struct(Ash.Filter, %{
          expression: %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
        })

      assert {"status = ?", ["active"]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "BooleanExpression struct combines operands with AND" do
      f1 = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
      f2 = %{operator: :gt, left: %{name: "age"}, right: %{value: 18}}

      filter =
        struct(Ash.Query.BooleanExpression, op: :and, left: f1, right: f2)

      assert {"status = ? AND age > ?", ["active", 18]} =
               QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end
  end

  describe "AND error propagation for unknown-filter operands" do
    test "left operand error short-circuits the conjunction" do
      fun = fn -> :ok end
      eqf = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}

      assert {:error, {:unknown_filter, unknown}} =
               QueryBuilder.filter_to_cql(%{op: :and, left: fun, right: eqf}, %MapSet{}, %{})

      assert is_function(unknown)
    end

    test "right operand error propagates as well" do
      fun = fn -> :ok end
      eqf = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}

      assert {:error, {:unknown_filter, unknown}} =
               QueryBuilder.filter_to_cql(%{op: :and, left: eqf, right: fun}, %MapSet{}, %{})

      assert is_function(unknown)
    end
  end

  describe "raw-value operator branches in translate_operator" do
    test "exists maps to IS NOT NULL without params" do
      filter = %{operator: :exists, left: %{name: :email}, right: fn -> :ok end}

      assert {"email IS NOT NULL", []} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "contains_key keeps the raw value param" do
      ref = make_ref()
      filter = %{operator: :contains_key, left: %{name: :opts}, right: ref}

      assert {"opts CONTAINS KEY ?", [^ref]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "contains_key with a plain binary right side routes through operator_cql" do
      filter = %{operator: :contains_key, left: %{name: :opts}, right: "k"}

      assert {"opts CONTAINS KEY ?", ["k"]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "has keeps the raw value param" do
      ref = make_ref()
      filter = %{operator: :has, left: %{name: :tags}, right: ref}

      assert {"tags CONTAINS ?", [^ref]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "overlaps keeps the raw value param" do
      ref = make_ref()
      filter = %{operator: :overlaps, left: %{name: :tags}, right: ref}

      assert {"tags CONTAINS ?", [^ref]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "comparison operators keep the raw value param untouched" do
      fun = fn x -> x end
      filter = %{operator: :gte, left: %{name: :score}, right: fun}

      {cql, params} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      assert cql == "score >= ?"
      assert [param] = params
      assert param == fun
    end

    test "starts_with with unusable raw value raises while building the LIKE parameter" do
      filter = %{operator: :starts_with, left: %{name: :name}, right: make_ref()}

      assert_raise ArgumentError, fn ->
        QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      end
    end

    test "ends_with with unusable raw value raises while building the LIKE parameter" do
      filter = %{operator: :ends_with, left: %{name: :email}, right: make_ref()}

      assert_raise ArgumentError, fn ->
        QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      end
    end

    test "contains with unusable raw value raises while building the LIKE parameter" do
      filter = %{operator: :contains, left: %{name: :bio}, right: make_ref()}

      assert_raise ArgumentError, fn ->
        QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      end
    end
  end

  describe "token operator clauses" do
    test "token with wrapped key list renders a TOKEN equality clause" do
      filter = %{operator: :token, left: %{name: :abc}, right: %{value: [:x]}}

      assert {"TOKEN(abc) = TOKEN(?)", [:x]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "token with raw key list renders one placeholder per key" do
      filter = %{operator: :token, left: %{name: :abc}, right: [:x, :y]}

      assert {"TOKEN(abc) = TOKEN(?, ?)", [:x, :y]} =
               QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end
  end

  describe "has and overlaps raw-value dispatch" do
    test "has with raw value produces CONTAINS" do
      filter = %{operator: :has, left: %{name: :tags}, right: "admin"}
      assert {"tags CONTAINS ?", ["admin"]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "overlaps with bare MapSet routes through handle_overlaps_mapset" do
      filter = %{operator: :overlaps, left: %{name: :tags}, right: MapSet.new(["admin"])}

      assert {"tags CONTAINS ?", ["admin"]} = QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "overlaps with empty MapSet builds an unsatisfiable condition" do
      filter = %{operator: :overlaps, left: %{name: :tags}, right: MapSet.new()}

      assert {"tags = ? AND tags != ?", [nil, nil]} =
               QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
    end

    test "overlaps with multi-element MapSet raises" do
      filter = %{operator: :overlaps, left: %{name: :tags}, right: MapSet.new(["a", "b"])}

      assert_raise AshScylla.Error, ~r/does not support OR/, fn ->
        QueryBuilder.filter_to_cql(filter, %MapSet{}, %{})
      end
    end
  end

  describe "split_aware reraise for errors without or_split" do
    test "build_where_clause re-raises overlaps errors unchanged" do
      filter = %{operator: :overlaps, left: %{name: :tags}, right: %{value: ["x", "y"]}}

      error =
        assert_raise AshScylla.Error, ~r/does not support OR/, fn ->
          QueryBuilder.build_where_clause([filter])
        end

      assert %{or_split: nil} = error
    end

    test "AND operands re-raise non-split errors unchanged" do
      eqf = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}

      overlaps_multi = %{
        operator: :overlaps,
        left: %{name: :tags},
        right: %{value: ["x", "y"]}
      }

      assert_raise AshScylla.Error, ~r/does not support OR/, fn ->
        QueryBuilder.filter_to_cql(%{op: :and, left: eqf, right: overlaps_multi}, %MapSet{}, %{})
      end
    end
  end

  describe "arity-1 conversion wrappers" do
    test "filter_to_cql/1 defaults uuid fields and cql types" do
      filter = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
      assert {"status = ?", ["active"]} = QueryBuilder.filter_to_cql(filter)
    end

    test "filter_to_cql!/1 returns tuples on success" do
      filter = %{operator: :eq, left: %{name: "status"}, right: %{value: "active"}}
      assert {"status = ?", ["active"]} = QueryBuilder.filter_to_cql!(filter)
    end

    test "filter_to_cql!/3 raises ArgumentError on unknown filters" do
      assert_raise ArgumentError, ~r/Unknown filter expression/, fn ->
        QueryBuilder.filter_to_cql!(fn -> :ok end, %MapSet{}, %{})
      end
    end
  end

  describe "build_contains_clause/3" do
    test ":contains variant" do
      assert {~s(tags CONTAINS ?), ["admin"]} =
               QueryBuilder.build_contains_clause(:tags, "admin", :contains)
    end

    test ":contains_key variant" do
      assert {~s(opts CONTAINS KEY ?), ["k"]} =
               QueryBuilder.build_contains_clause("opts", "k", :contains_key)
    end
  end

  describe "same-field OR rewrite shapes" do
    test "op-key filters with value-wrapped rights rewrite to IN" do
      left = %{left: %{name: :status}, op: :==, right: %{value: "a"}}
      right = %{left: %{name: :status}, op: :==, right: %{value: "b"}}

      assert {"status IN (?, ?)", ["a", "b"]} =
               QueryBuilder.filter_to_cql(
                 %{operator: :or, left: left, right: right},
                 %MapSet{},
                 %{}
               )
    end

    test "op-key filters with raw rights rewrite to IN" do
      left = %{left: %{name: :age}, op: :==, right: 18}
      right = %{left: %{name: :age}, op: :==, right: %{value: 21}}

      assert {"age IN (?, ?)", [18, 21]} =
               QueryBuilder.filter_to_cql(
                 %{operator: :or, left: left, right: right},
                 %MapSet{},
                 %{}
               )
    end

    test "bare name/op filters rewrite to IN" do
      left = %{name: :status, op: :==, right: "a"}
      right = %{name: :status, op: :==, right: %{value: "b"}}

      assert {"status IN (?, ?)", ["a", "b"]} =
               QueryBuilder.filter_to_cql(
                 %{operator: :or, left: left, right: right},
                 %MapSet{},
                 %{}
               )
    end

    test "OR across incompatible operands raises with unwrapped expressions" do
      left = %{value: "a"}
      right = %{left: %{name: :other}, operator: :eq, right: %{value: "c"}}

      assert_raise AshScylla.Error, ~r/does not support OR/, fn ->
        QueryBuilder.filter_to_cql(%{operator: :or, left: left, right: right}, %MapSet{}, %{})
      end
    end
  end

  describe "typed_param declared-type wrapping" do
    test "declared int type is kept instead of falling back to inference" do
      filter = %{operator: :gt, left: %{name: :count}, right: %{value: 5}}

      assert {"count > ?", [{"int", 5}]} =
               QueryBuilder.filter_to_cql(filter, MapSet.new([:count]), %{:count => "int"})
    end
  end

  describe "can_use_secondary_index?/2 column extraction paths" do
    test "expression-wrapped filters expose their inner columns" do
      filter = %{expression: %{left: %{name: :email}}}
      assert {:ok, [:email]} = QueryBuilder.can_use_secondary_index?(QbmIdxResource, [filter])
    end

    test "function-struct filters extract columns from arguments" do
      filter = %{
        __function__?: true,
        name: :contains,
        arguments: [%{left: %{name: :email}}, %{left: %{name: :name}}]
      }

      assert {:ok, [:email, :name]} =
               QueryBuilder.can_use_secondary_index?(QbmIdxResource, [filter])
    end
  end
end
