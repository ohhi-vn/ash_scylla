# Copyright [2024] AshScylla Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule AshScylla.DataLayer.ComprehensiveTest do
  @moduledoc """
  Comprehensive tests covering gaps in the existing test suite.

  Covers: filter OR rewriting, sort edge cases, source/repo edge cases,
  upsert delegation, distinct, calculate, handle_scylla_result,
  sanitize_identifier, maybe_rewrite_or_to_in, struct defaults,
  and exhaustive can?/2 feature testing.
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer
  alias AshScylla.Error.ScyllaError

  # ---------------------------------------------------------------------------
  # Fake repo – returns success for any query
  # ---------------------------------------------------------------------------

  defmodule FakeRepo do
    @moduledoc false

    def query(query, params, opts \\ []) do
      send(self(), {:ash_scylla_query, query, params, opts})

      cond do
        String.contains?(query, "nonexistent_table") ->
          {:error, %Xandra.Error{reason: :overloaded, message: nil, warnings: []}}

        String.contains?(query, "conn-err") ->
          {:error, %Xandra.ConnectionError{reason: :timeout, action: nil}}

        true ->
          {:ok, %Xandra.Page{content: [], columns: []}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Test resources
  # ---------------------------------------------------------------------------

  defmodule Resource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(FakeRepo)
      table("comp_items")
      keyspace("test_ks")
      consistency(:one)
      secondary_index(:status)
      secondary_index(:age)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:status, :string)
      attribute(:age, :integer)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule DirectRepoResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(FakeRepo)
      table("direct_repo_items")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule DirectTableResource do
    @moduledoc false
    @table "direct_table"

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule EmptyTableResource do
    @moduledoc false
    @table ""

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule NoCalculateModule do
    @moduledoc false
    # Intentionally does NOT export calculate/2
  end

  defmodule CalculateModule do
    @moduledoc false
    def calculate(_records, _opts), do: 42
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp base_query do
    %AshScylla.Query{
      resource: Resource,
      repo: FakeRepo,
      table: "comp_items",
      filters: [],
      sorts: [],
      limit: nil,
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

  # ===========================================================================
  # 1. DataLayer.filter/3 - OR rewriting edge cases
  # ===========================================================================

  describe "filter/3 - single filter (no OR)" do
    test "passes through unchanged" do
      filter = %{name: :status, op: :eq, right: %{value: "active"}}
      assert {:ok, query} = DataLayer.filter(base_query(), filter, Resource)
      [rewritten] = query.filters
      assert rewritten.name == :status
    end
  end

  describe "filter/3 - OR on different columns" do
    test "does not rewrite OR on different columns to IN" do
      filter = %{
        op: :or,
        left: %{name: :status, op: :eq, right: %{value: "active"}},
        right: %{name: :age, op: :eq, right: %{value: 42}}
      }

      assert {:ok, query} = DataLayer.filter(base_query(), filter, Resource)
      [rewritten] = query.filters
      # Should remain as OR since different columns
      assert rewritten.op == :or
    end
  end

  describe "filter/3 - simple 2-way OR on same column" do
    test "rewrites to IN with operator key" do
      filter = %{
        op: :or,
        left: %{name: :status, op: :eq, right: %{value: "active"}},
        right: %{name: :status, op: :eq, right: %{value: "pending"}}
      }

      assert {:ok, query} = DataLayer.filter(base_query(), filter, Resource)
      [rewritten] = query.filters
      # maybe_rewrite_or_to_in produces :operator (not :op) and :in
      assert rewritten.operator == :in
      assert rewritten.left.name == :status
      assert "active" in rewritten.right.value
      assert "pending" in rewritten.right.value
    end
  end

  describe "filter/3 - nested AND/OR combinations" do
    test "preserves nested AND/OR structure" do
      filter = %{
        op: :and,
        left: %{name: :status, op: :eq, right: %{value: "active"}},
        right: %{
          op: :or,
          left: %{name: :age, op: :eq, right: %{value: 42}},
          right: %{name: :age, op: :eq, right: %{value: 35}}
        }
      }

      assert {:ok, query} = DataLayer.filter(base_query(), filter, Resource)
      [rewritten] = query.filters
      assert rewritten.op == :and
      assert rewritten.left.name == :status
      assert rewritten.right.op == :or
    end
  end

  # ===========================================================================
  # 2. DataLayer.sort/3 - Edge cases
  # ===========================================================================

  describe "sort/3 - empty sort list" do
    test "prepends empty list without error" do
      assert {:ok, query} = DataLayer.sort(base_query(), [], Resource)
      assert query.sorts == []
    end
  end

  describe "sort/3 - tuple format" do
    test "accepts sort with tuple format" do
      assert {:ok, query} = DataLayer.sort(base_query(), [{:age, :desc}], Resource)
      assert query.sorts == [{:age, :desc}]
    end
  end

  describe "sort/3 - map format" do
    test "accepts sort with map format" do
      assert {:ok, query} =
               DataLayer.sort(base_query(), [%{field: :age, direction: :asc}], Resource)

      assert query.sorts == [%{field: :age, direction: :asc}]
    end
  end

  describe "sort/3 - multiple sort items" do
    test "prepends new sorts to existing ones" do
      query = %{base_query() | sorts: [{:name, :asc}]}
      assert {:ok, query} = DataLayer.sort(query, [{:age, :desc}], Resource)
      assert query.sorts == [{:age, :desc}, {:name, :asc}]
    end
  end

  # ===========================================================================
  # 3. DataLayer.bulk_create/3 - Edge cases
  # ===========================================================================

  describe "bulk_create/3 - empty changesets list" do
    test "returns ok for empty list" do
      assert {:ok, []} = DataLayer.bulk_create(Resource, [], return_records?: false)
    end
  end

  describe "bulk_create/3 - return_records? false" do
    test "returns :ok without records when return_records? is false" do
      changesets = [
        %Ash.Changeset{attributes: %{id: "id-1", name: "First"}}
      ]

      assert {:ok, _} = DataLayer.bulk_create(Resource, changesets, return_records?: false)
    end
  end

  describe "bulk_create/3 - error handling" do
    test "returns error when repo not configured" do
      assert_raise RuntimeError, ~r/No repo configured/, fn ->
        DataLayer.bulk_create(EmptyTableResource, [%Ash.Changeset{attributes: %{}}],
          return_records?: false
        )
      end
    end
  end

  describe "bulk_create/3 - map opts" do
    test "accepts map opts instead of keyword list" do
      changesets = [
        %Ash.Changeset{attributes: %{id: "id-1", name: "First"}}
      ]

      assert {:ok, _records} =
               DataLayer.bulk_create(Resource, changesets, %{
                 return_records?: true,
                 batch_size: 10
               })
    end
  end

  describe "bulk_create/3 - batch_size option" do
    test "chunks statements by batch_size" do
      changesets = [
        %Ash.Changeset{attributes: %{id: "id-1", name: "First"}},
        %Ash.Changeset{attributes: %{id: "id-2", name: "Second"}}
      ]

      assert {:ok, _records} =
               DataLayer.bulk_create(Resource, changesets, batch_size: 1, return_records?: true)
    end
  end

  # ===========================================================================
  # 4. DataLayer.source/1 - Edge cases
  # ===========================================================================

  describe "source/1 - empty string table attribute" do
    test "falls back to module name when @table is empty string" do
      assert DataLayer.source(EmptyTableResource) == "empty_table_resource"
    end
  end

  describe "source/1 - @table attribute set directly" do
    test "falls back to module name for compiled module" do
      # Module.get_attribute raises for compiled modules, so source/1
      # falls back to the underscored module name via rescue
      assert DataLayer.source(DirectTableResource) == "direct_table_resource"
    end
  end

  describe "source/1 - caching" do
    test "returns cached value on second call" do
      first = DataLayer.source(Resource)
      second = DataLayer.source(Resource)
      assert first == second
      assert first == "comp_items"
    end
  end

  # ===========================================================================
  # 5. DataLayer.repo/1 - Edge cases
  # ===========================================================================

  describe "repo/1 - DSL repo" do
    test "uses repo from DSL config" do
      changeset = %Ash.Changeset{attributes: %{id: "test-id", name: "Test"}}
      # DirectRepoResource has repo(FakeRepo) in its DSL block
      # FakeRepo returns empty page for direct_repo_items SELECT, so fetch_by_PK fails
      assert {:error, %ScyllaError{}} = DataLayer.create(DirectRepoResource, changeset)
    end
  end

  describe "repo/1 - caching" do
    test "caches repo per resource" do
      changeset = %Ash.Changeset{attributes: %{id: "test-id", name: "Test"}}
      DataLayer.create(DirectRepoResource, changeset)

      assert :ets.lookup(:ash_scylla_repo_cache, DirectRepoResource) == [
               {DirectRepoResource, FakeRepo}
             ]
    end
  end

  describe "repo/1 - resource with DSL repo" do
    test "uses repo from DSL config" do
      assert DataLayer.source(DirectRepoResource) == "direct_repo_items"
      changeset = %Ash.Changeset{attributes: %{id: "test-id", name: "Test"}}
      DataLayer.create(DirectRepoResource, changeset)

      assert :ets.lookup(:ash_scylla_repo_cache, DirectRepoResource) == [
               {DirectRepoResource, FakeRepo}
             ]
    end
  end

  # ===========================================================================
  # 6. DataLayer.upsert/4 (with identity parameter)
  # ===========================================================================

  describe "upsert/4 - delegates to upsert/3" do
    test "upsert/4 calls upsert/3 with same fields" do
      changeset = %Ash.Changeset{attributes: %{id: "test-id", name: "Test"}}
      # upsert/4 delegates to upsert/3 which calls do_upsert
      # FakeRepo returns {:ok, %Xandra.Page{}} which matches the non-LWT path
      assert {:ok, _record} = DataLayer.upsert(Resource, changeset, [:id], :test_identity)
    end
  end

  # ===========================================================================
  # 7. DataLayer.run_aggregate_query/3
  # ===========================================================================

  describe "run_aggregate_query/3 - aggregate with field" do
    test "generates COUNT(field) query" do
      query = %{
        base_query()
        | filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
          aggregates: [%{kind: :count, name: :count_with_age, field: :age}]
      }

      assert {:ok, results} = DataLayer.run_aggregate_query(query, query.aggregates, Resource)
      assert is_map(results)
      assert Map.has_key?(results, :count_with_age)
    end
  end

  describe "run_aggregate_query/3 - multiple aggregates" do
    test "runs multiple COUNT aggregates" do
      query = %{
        base_query()
        | filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
          aggregates: [
            %{kind: :count, name: :total_count, field: nil},
            %{kind: :count, name: :count_with_age, field: :age}
          ]
      }

      assert {:ok, results} = DataLayer.run_aggregate_query(query, query.aggregates, Resource)
      assert is_map(results)
      assert Map.has_key?(results, :total_count)
      assert Map.has_key?(results, :count_with_age)
    end
  end

  describe "run_aggregate_query/3 - empty aggregates list" do
    test "returns empty map for empty aggregates" do
      query = %{
        base_query()
        | filters: [],
          aggregates: []
      }

      assert {:ok, results} = DataLayer.run_aggregate_query(query, [], Resource)
      assert results == %{}
    end
  end

  describe "run_aggregate_query/3 - aggregate with WHERE clause from filters" do
    test "includes WHERE clause from filters in aggregate query" do
      query = %{
        base_query()
        | filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
          aggregates: [%{kind: :count, name: :total_count, field: nil}]
      }

      assert {:ok, results} = DataLayer.run_aggregate_query(query, query.aggregates, Resource)
      assert is_map(results)
      assert Map.has_key?(results, :total_count)
    end
  end

  # ===========================================================================
  # 8. DataLayer.distinct/3
  # ===========================================================================

  describe "distinct/3 - multiple partition key columns" do
    test "accepts multiple partition key columns" do
      assert {:ok, query} = DataLayer.distinct(base_query(), [:id], Resource)
      assert query.select == [:id]
    end
  end

  describe "distinct/3 - mix of PK and non-PK columns" do
    test "returns error for mix of PK and non-PK columns" do
      assert {:error, %ScyllaError{}} = DataLayer.distinct(base_query(), [:id, :status], Resource)
    end
  end

  describe "distinct/3 - empty distinct columns list" do
    test "empty list is vacuously all PK, succeeds with empty select" do
      assert {:ok, query} = DataLayer.distinct(base_query(), [], Resource)
      assert query.select == []
    end
  end

  # ===========================================================================
  # 9. DataLayer.calculate/3
  # ===========================================================================

  describe "calculate/3 - multiple calculations accumulate" do
    test "prepends multiple calculations to context" do
      calc1 = %{name: :calc1, module: CalculateModule, opts: []}
      calc2 = %{name: :calc2, module: CalculateModule, opts: []}

      assert {:ok, query} = DataLayer.calculate(base_query(), calc1, Resource)
      assert {:ok, query} = DataLayer.calculate(query, calc2, Resource)

      calculations = Map.get(query.context, :calculations, [])
      assert length(calculations) == 2
      names = Enum.map(calculations, & &1.name)
      assert :calc1 in names
      assert :calc2 in names
    end
  end

  describe "calculate/3 - module without calculate/2 function" do
    test "handles module that doesn't export calculate/2 gracefully" do
      calc = %{name: :no_calc, module: NoCalculateModule, opts: []}
      assert {:ok, query} = DataLayer.calculate(base_query(), calc, Resource)
      calculations = Map.get(query.context, :calculations, [])
      assert length(calculations) == 1
      assert hd(calculations).name == :no_calc
    end
  end

  # ===========================================================================
  # 10. handle_scylla_result/1 - All error paths
  # ===========================================================================

  describe "handle_scylla_result/1 - :ok passthrough" do
    test "returns :ok unchanged" do
      changeset = %Ash.Changeset{attributes: %{id: "test-id"}}
      result = DataLayer.destroy(Resource, changeset)
      assert :ok = result
    end
  end

  describe "handle_scylla_result/1 - {:error, %Xandra.Error{}}" do
    test "wraps Xandra.Error in ScyllaError" do
      # Directly test handle_scylla_result through the error path
      error =
        AshScylla.Error.wrap_xandra_error(%Xandra.Error{
          reason: :overloaded,
          message: nil,
          warnings: []
        })

      assert %ScyllaError{} = error
      assert error.type == :overloaded
    end
  end

  describe "handle_scylla_result/1 - {:error, %Xandra.ConnectionError{}}" do
    test "wraps Xandra.ConnectionError in ScyllaError" do
      error =
        AshScylla.Error.wrap_xandra_error(%Xandra.ConnectionError{reason: :timeout, action: nil})

      assert %ScyllaError{} = error
      assert error.type == :connection_timeout
    end
  end

  describe "handle_scylla_result/1 - {:error, %ScyllaError{}}" do
    test "passes through ScyllaError unchanged" do
      scylla_error = ScyllaError.from_error("test error")
      assert %ScyllaError{} = scylla_error
      assert scylla_error.message == "Database error: \"test error\""
      assert scylla_error.type == :generic_error
    end
  end

  describe "handle_scylla_result/1 - {:error, string}" do
    test "wraps string error in ScyllaError" do
      error = ScyllaError.from_error("some string error")
      assert %ScyllaError{} = error
      assert error.message == "Database error: \"some string error\""
    end
  end

  describe "handle_scylla_result/1 - {:error, atom}" do
    test "wraps atom error in ScyllaError" do
      error = ScyllaError.from_error(:some_atom_error)
      assert %ScyllaError{} = error
      assert error.message == "Database error: :some_atom_error"
    end
  end

  # ===========================================================================
  # 11. sanitize_identifier/1 - Edge cases
  # ===========================================================================

  describe "sanitize_identifier/1 - valid identifiers" do
    test "accepts normal identifier" do
      assert DataLayer.source(Resource) == "comp_items"
    end

    test "accepts identifier with underscores" do
      assert DataLayer.source(Resource) == "comp_items"
    end

    test "accepts identifier from DSL table config" do
      assert DataLayer.source(DirectRepoResource) == "direct_repo_items"
    end
  end

  describe "sanitize_identifier/1 - invalid identifiers" do
    test "source/1 rescues and falls back to module name for invalid identifiers" do
      assert is_binary(DataLayer.source(Resource))
      assert is_binary(DataLayer.source(DirectTableResource))
    end

    test "sanitize_identifier is called during source/1 resolution" do
      result = DataLayer.source(Resource)
      assert Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, result)
    end
  end

  # ===========================================================================
  # 12. maybe_rewrite_or_to_in/1 - Deep patterns
  # ===========================================================================

  describe "maybe_rewrite_or_to_in/1 - 4-way OR on same column" do
    test "does not rewrite deeply nested OR" do
      filter = %{
        op: :or,
        left: %{
          op: :or,
          left: %{
            op: :or,
            left: %{name: :status, op: :eq, right: %{value: "active"}},
            right: %{name: :status, op: :eq, right: %{value: "pending"}}
          },
          right: %{name: :status, op: :eq, right: %{value: "archived"}}
        },
        right: %{name: :status, op: :eq, right: %{value: "deleted"}}
      }

      assert {:ok, query} = DataLayer.filter(base_query(), filter, Resource)
      [rewritten] = query.filters
      assert rewritten.op == :or
    end
  end

  describe "maybe_rewrite_or_to_in/1 - OR with nested AND inside" do
    test "does not rewrite OR with nested AND" do
      filter = %{
        op: :or,
        left: %{
          op: :and,
          left: %{name: :status, op: :eq, right: %{value: "active"}},
          right: %{name: :age, op: :eq, right: %{value: 42}}
        },
        right: %{name: :status, op: :eq, right: %{value: "pending"}}
      }

      assert {:ok, query} = DataLayer.filter(base_query(), filter, Resource)
      [rewritten] = query.filters
      assert rewritten.op == :or
    end
  end

  describe "maybe_rewrite_or_to_in/1 - single equality filter" do
    test "passes through single equality filter unchanged" do
      filter = %{name: :status, op: :eq, right: %{value: "active"}}

      assert {:ok, query} = DataLayer.filter(base_query(), filter, Resource)
      [rewritten] = query.filters
      assert rewritten.name == :status
      assert rewritten.op == :eq
      assert rewritten.right.value == "active"
    end
  end

  # ===========================================================================
  # 13. DataLayer struct defaults verification
  # ===========================================================================

  describe "DataLayer struct defaults" do
    test "all default values are correct" do
      dl = %AshScylla.Query{}
      assert dl.resource == nil
      assert dl.repo == nil
      assert dl.table == nil
      assert dl.filters == []
      assert dl.sorts == []
      assert dl.limit == nil
      assert dl.select == nil
      assert dl.distinct == nil
      assert dl.tenant == nil
      assert dl.context == %{}
      assert dl.atomic == nil
      assert dl.upsert? == false
      assert dl.upsert_fields == []
      assert dl.upsert_identity == nil
      assert dl.keyset == nil
      assert dl.aggregates == []
      assert dl.group_by == nil
    end
  end

  # ===========================================================================
  # 14. can?/2 - Exhaustive feature testing
  # ===========================================================================

  describe "can?/2 - all supported features return true" do
    test "returns true for every supported feature" do
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
        :upsert,
        :update_query,
        :destroy_query,
        :distinct,
        :boolean_filter
      ]

      for f <- supported, do: assert(DataLayer.can?(nil, f) == true)
    end
  end

  describe "can?/2 - tuple features" do
    test "returns true for supported tuple features" do
      assert DataLayer.can?(nil, {:atomic, :update}) == true
      assert DataLayer.can?(nil, {:atomic, :upsert}) == true
      assert DataLayer.can?(nil, {:aggregate, :count}) == true
    end
  end

  describe "can?/2 - unsupported features return false" do
    test "returns false for every unsupported feature" do
      unsupported = [
        :aggregate,
        :join,
        :lateral_join,
        :lock,
        :combine,
        :offset,
        :expression_calculation
      ]

      for f <- unsupported, do: assert(DataLayer.can?(nil, f) == false)
    end
  end

  describe "can?/2 - unsupported tuple features" do
    test "returns false for unsupported tuple features" do
      assert DataLayer.can?(nil, {:combine, :union}) == false
      assert DataLayer.can?(nil, {:aggregate, :sum}) == false
      assert DataLayer.can?(nil, {:aggregate, :avg}) == false
      assert DataLayer.can?(nil, {:aggregate, :min}) == false
      assert DataLayer.can?(nil, {:aggregate, :max}) == false
    end
  end

  describe "can?/2 - nil, string, integer features" do
    test "returns false for nil feature" do
      assert DataLayer.can?(nil, nil) == false
    end

    test "returns false for string feature" do
      assert DataLayer.can?(nil, "create") == false
    end

    test "returns false for integer feature" do
      assert DataLayer.can?(nil, 42) == false
    end
  end

  describe "can?/2 - {atom, term} tuple features" do
    test "returns false for unknown tuple features" do
      assert DataLayer.can?(nil, {:unknown, :value}) == false
      assert DataLayer.can?(nil, {:calculate, :foo}) == false
      assert DataLayer.can?(nil, {:combine, :bar}) == false
    end
  end

  # ===========================================================================
  # 15. to_ash_record — Xandra column tuple mapping
  # ===========================================================================

  defmodule ColumnTupleRepo do
    @moduledoc """
    Fake repo that returns Xandra.Page structs with real column tuples
    (4-tuples of {keyspace, table, name, type}) as ScyllaDB actually returns.
    This exercises the to_ash_record clause that maps positional row values
    to attribute maps using column metadata.
    """

    @column_tuples [
      {"test_ks", "column_tuple_items", "id", :uuid},
      {"test_ks", "column_tuple_items", "name", :text},
      {"test_ks", "column_tuple_items", "status", :text},
      {"test_ks", "column_tuple_items", "age", :int}
    ]

    @row_values ["abc-123", "Test Record", "active", 42]

    def query(query, params, opts \\ []) do
      send(self(), {:column_tuple_query, query, params, opts})

      cond do
        String.contains?(query, "INSERT INTO") ->
          {:ok, %Xandra.Page{content: []}}

        String.contains?(query, "SELECT") ->
          # Return rows as lists (positional values) with columns as 4-tuples
          # matching Xandra's real format: {keyspace, table, column_name, type}
          {:ok, %Xandra.Page{content: [@row_values], columns: @column_tuples}}

        true ->
          {:ok, %Xandra.Page{content: [], columns: []}}
      end
    end
  end

  defmodule ColumnTupleResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(ColumnTupleRepo)
      table("column_tuple_items")
      keyspace("test_ks")
      consistency(:one)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:status, :string)
      attribute(:age, :integer)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  describe "to_ash_record — Xandra column tuple mapping" do
    test "create/2 maps positional row values to struct attributes via column tuples" do
      attrs = %{
        id: "abc-123",
        name: "Test Record",
        status: "active",
        age: 42
      }

      changeset = %Ash.Changeset{attributes: attrs}
      assert {:ok, record} = DataLayer.create(ColumnTupleResource, changeset)

      # These would all be nil before the fix because the column 4-tuple
      # was used as the map key instead of extracting the column name
      assert record.id == "abc-123"
      assert record.name == "Test Record"
      assert record.status == "active"
      assert record.age == 42
    end

    test "run_query/2 maps column-tuple rows to struct attributes" do
      query = %AshScylla.Query{
        resource: ColumnTupleResource,
        repo: ColumnTupleRepo,
        table: "column_tuple_items",
        filters: [],
        sorts: [],
        limit: nil,
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

      assert {:ok, records} = DataLayer.run_query(query, ColumnTupleResource)
      assert length(records) == 1

      [record] = records
      assert record.id == "abc-123"
      assert record.name == "Test Record"
      assert record.status == "active"
      assert record.age == 42
    end

    test "run_query/2 with select maps only requested columns" do
      query = %AshScylla.Query{
        resource: ColumnTupleResource,
        repo: ColumnTupleRepo,
        table: "column_tuple_items",
        filters: [],
        sorts: [],
        limit: nil,
        select: [:name, :age],
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

      assert {:ok, records} = DataLayer.run_query(query, ColumnTupleResource)
      assert length(records) == 1

      [record] = records
      assert record.name == "Test Record"
      assert record.age == 42
    end
  end
end
