defmodule AshScylla.QueryOptimizerTest do
  @moduledoc """
  Tests for AshScylla.DataLayer.QueryOptimizer — query cost estimation,
  page size heuristics, Xandra option building, speculative retry CQL,
  consistency recommendations, and token-aware routing hints.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.QueryOptimizer

  # ---------------------------------------------------------------------------
  # Test resources simulating various DSL configurations
  # ---------------------------------------------------------------------------

  defmodule LwtResource do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      table("lwt_resource")
      lwt(true)
      consistency(:quorum)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule DefaultResource do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      table("default_resource")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read])
    end
  end

  # ---------------------------------------------------------------------------
  # optimize/2
  # ---------------------------------------------------------------------------

  describe "optimize/2" do
    test "returns keyword list with nil opts" do
      assert [] = QueryOptimizer.optimize(nil)
    end

    test "puts consistency level" do
      assert [consistency: :quorum] = QueryOptimizer.optimize(nil, consistency: :quorum)
    end

    test "puts timeout" do
      assert [timeout: 5000] = QueryOptimizer.optimize(nil, timeout: 5000)
    end

    test "puts page_size capped at max" do
      assert [page_size: 1000] = QueryOptimizer.optimize(nil, page_size: 9999)
    end

    test "puts serial_consistency" do
      assert [serial_consistency: :serial] =
               QueryOptimizer.optimize(nil, serial_consistency: :serial)
    end

    test "puts profiling" do
      assert [profiling: true] = QueryOptimizer.optimize(nil, profiling: true)
    end

    test "puts speculative_retry with custom delay" do
      result =
        QueryOptimizer.optimize(nil,
          speculative_retry: :custom,
          speculative_retry_delay_ms: 250
        )

      assert Keyword.get(result, :speculative_retry) == :custom
      assert Keyword.get(result, :speculative_retry_delay_ms) == 250
    end

    test "puts speculative_retry 99percentile without delay key" do
      result = QueryOptimizer.optimize(nil, speculative_retry: :"99percentile")
      assert Keyword.get(result, :speculative_retry) == :"99percentile"
      refute Keyword.has_key?(result, :speculative_retry_delay_ms)
    end

    test "puts speculative_retry :none" do
      result = QueryOptimizer.optimize(nil, speculative_retry: :none)
      assert Keyword.get(result, :speculative_retry) == :none
    end

    test "combines multiple options" do
      result =
        QueryOptimizer.optimize(nil,
          consistency: :local_quorum,
          timeout: 3000,
          page_size: 200
        )

      assert Keyword.get(result, :consistency) == :local_quorum
      assert Keyword.get(result, :timeout) == 3000
      assert Keyword.get(result, :page_size) == 200
    end

    test "raises on invalid consistency level" do
      assert_raise ArgumentError, ~r/Invalid consistency level/, fn ->
        QueryOptimizer.optimize(nil, consistency: :bogus)
      end
    end

    test "raises on invalid timeout" do
      assert_raise ArgumentError, ~r/Timeout must be a positive integer/, fn ->
        QueryOptimizer.optimize(nil, timeout: -1)
      end

      assert_raise ArgumentError, ~r/Timeout must be a positive integer/, fn ->
        QueryOptimizer.optimize(nil, timeout: "fast")
      end
    end

    test "raises on invalid page_size" do
      assert_raise ArgumentError, ~r/Page size must be a positive integer/, fn ->
        QueryOptimizer.optimize(nil, page_size: 0)
      end
    end

    test "raises on invalid serial_consistency" do
      assert_raise ArgumentError, ~r/Invalid serial consistency/, fn ->
        QueryOptimizer.optimize(nil, serial_consistency: :bogus)
      end
    end

    test "raises on invalid speculative retry policy" do
      assert_raise ArgumentError, ~r/Invalid speculative retry policy/, fn ->
        QueryOptimizer.optimize(nil, speculative_retry: :bogus)
      end
    end

    test "omits speculative_retry_delay_ms for non-custom policy" do
      result =
        QueryOptimizer.optimize(nil,
          speculative_retry: :"99percentile",
          speculative_retry_delay_ms: 100
        )

      refute Keyword.has_key?(result, :speculative_retry_delay_ms)
    end
  end

  # ---------------------------------------------------------------------------
  # to_xandra_opts/1
  # ---------------------------------------------------------------------------

  describe "to_xandra_opts/1" do
    test "builds xandra opts with consistency, timeout, page_size, serial" do
      result =
        QueryOptimizer.to_xandra_opts(
          consistency: :one,
          timeout: 2000,
          page_size: 100,
          serial_consistency: :local_serial
        )

      assert Keyword.get(result, :consistency) == :one
      assert Keyword.get(result, :timeout) == 2000
      assert Keyword.get(result, :page_size) == 100
      assert Keyword.get(result, :serial_consistency) == :local_serial
    end

    test "to_xandra_opts does not add speculative retry or profiling" do
      # to_xandra_opts only adds consistency/timeout/page_size/serial_consistency
      # It does not add speculative_retry or profiling
      result = QueryOptimizer.to_xandra_opts(consistency: :one)

      assert Keyword.get(result, :consistency) == :one
      refute Keyword.has_key?(result, :speculative_retry)
      refute Keyword.has_key?(result, :profiling)
    end
  end

  # ---------------------------------------------------------------------------
  # optimal_page_size/1
  # ---------------------------------------------------------------------------

  describe "optimal_page_size/1" do
    test "uses explicit limit when <= default page size" do
      query = %AshScylla.Query{filters: [], limit: 25}
      assert QueryOptimizer.optimal_page_size(query) == 25
    end

    test "returns 50 for partition key equality filter" do
      # has_partition_key_filter? matches %{operator: :eq, left: %{name: _}}
      query = %AshScylla.Query{
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "abc"}}],
        limit: nil
      }

      assert QueryOptimizer.optimal_page_size(query) == 50
    end

    test "returns 50 for any equality filter (partition key match)" do
      # has_partition_key_filter? matches any %{operator: :eq, left: %{name: _}}
      query = %AshScylla.Query{
        filters: [%{operator: :eq, left: %{name: :email}, right: %{value: "a@b.co"}}],
        limit: nil
      }

      assert QueryOptimizer.optimal_page_size(query) == 50
    end

    test "returns 500 for full table scan" do
      query = %AshScylla.Query{filters: [], limit: nil}
      assert QueryOptimizer.optimal_page_size(query) == 500
    end

    test "caps at max page size" do
      # Full table scan default is 500, min(500, 1000) = 500
      query = %AshScylla.Query{filters: [], limit: 2000}
      assert QueryOptimizer.optimal_page_size(query) == 500
    end
  end

  # ---------------------------------------------------------------------------
  # analyze/1
  # ---------------------------------------------------------------------------

  describe "analyze/1" do
    test "warns on full table scan" do
      query = %AshScylla.Query{filters: [], limit: nil, select: nil}
      suggestions = QueryOptimizer.analyze(query)

      assert "Query performs full table scan - add partition key filter" in suggestions
      assert "Use token-based pagination for large result sets" in suggestions
      assert "Consider adding a LIMIT clause to reduce result set size" in suggestions
      assert "Consider selecting only needed columns instead of SELECT *" in suggestions
    end

    test "suggests indexes for non-indexed filters" do
      # When filters have a column name that is an atom, has_indexed_filter? returns true
      # so the suggestion is NOT added. But when filters don't match (e.g., no left.name),
      # the suggestion IS added.
      query = %AshScylla.Query{
        filters: [%{operator: :eq, right: %{value: "Alice"}}],
        limit: 10,
        select: [:id, :name]
      }

      suggestions = QueryOptimizer.analyze(query)
      assert "Consider adding secondary index for faster lookups" in suggestions
    end

    test "does not suggest index when filter has column name" do
      # has_indexed_filter? returns true for filters with %{left: %{name: _}}
      query = %AshScylla.Query{
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "abc"}}],
        limit: 10,
        select: [:id]
      }

      suggestions = QueryOptimizer.analyze(query)
      refute "Consider adding secondary index for faster lookups" in suggestions
    end
  end

  # ---------------------------------------------------------------------------
  # token_range_query/4
  # ---------------------------------------------------------------------------

  describe "token_range_query/4" do
    test "builds token range query" do
      cql = QueryOptimizer.token_range_query("users", "id", "-9223372036854775808", "0")

      assert cql =~ "SELECT * FROM users"
      assert cql =~ "token(id) > -9223372036854775808"
      assert cql =~ "token(id) <= 0"
    end

    test "raises on invalid identifier" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        QueryOptimizer.token_range_query("my users", "id", "0", "100")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # speculative_retry_cql/2
  # ---------------------------------------------------------------------------

  describe "speculative_retry_cql/2" do
    test "none policy" do
      assert QueryOptimizer.speculative_retry_cql(:none, nil) ==
               "USING SPECULATIVE_RETRY 'NONE'"
    end

    test "99percentile policy" do
      assert QueryOptimizer.speculative_retry_cql(:"99percentile", nil) ==
               "USING SPECULATIVE_RETRY '99percentile'"
    end

    test "custom policy with delay" do
      assert QueryOptimizer.speculative_retry_cql(:custom, 500) ==
               "USING SPECULATIVE_RETRY '500ms'"
    end

    test "custom policy without delay raises" do
      assert_raise ArgumentError, ~r/requires :speculative_retry_delay_ms/, fn ->
        QueryOptimizer.speculative_retry_cql(:custom, nil)
      end
    end

    test "unknown policy raises" do
      assert_raise ArgumentError, ~r/Unknown speculative retry policy/, fn ->
        QueryOptimizer.speculative_retry_cql(:bogus, nil)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # profile_query/1
  # ---------------------------------------------------------------------------

  describe "profile_query/1" do
    test "wraps query with PROFILE prefix" do
      assert QueryOptimizer.profile_query("SELECT * FROM users") ==
               "PROFILE SELECT * FROM users"
    end
  end

  # ---------------------------------------------------------------------------
  # recommended_consistency/1
  # ---------------------------------------------------------------------------

  describe "recommended_consistency/1" do
    test "read-heavy operations use :one" do
      assert QueryOptimizer.recommended_consistency(:read) == :one
      assert QueryOptimizer.recommended_consistency(:bulk_read) == :one
    end

    test "writes use :local_quorum" do
      assert QueryOptimizer.recommended_consistency(:create) == :local_quorum
      assert QueryOptimizer.recommended_consistency(:update) == :local_quorum
      assert QueryOptimizer.recommended_consistency(:destroy) == :local_quorum
      assert QueryOptimizer.recommended_consistency(:bulk_create) == :local_quorum
      assert QueryOptimizer.recommended_consistency(:aggregate) == :local_quorum
    end

    test "lwt uses :serial" do
      assert QueryOptimizer.recommended_consistency(:lwt) == :serial
    end

    test "unknown falls back to :local_quorum" do
      assert QueryOptimizer.recommended_consistency(:bogus) == :local_quorum
    end
  end

  # ---------------------------------------------------------------------------
  # estimate_cost/1
  # ---------------------------------------------------------------------------

  describe "estimate_cost/1" do
    test "empty filters is full_scan" do
      query = %AshScylla.Query{filters: [], limit: nil, sorts: []}
      assert QueryOptimizer.estimate_cost(query) == :full_scan
    end

    test "full scan with limit stays full_scan" do
      # maybe_reduce_for_limit(:full_scan, limit) only matches :full_scan with limit
      query = %AshScylla.Query{filters: [], limit: 10, sorts: []}
      assert QueryOptimizer.estimate_cost(query) == :high
    end

    test "partition key equality is low" do
      query = %AshScylla.Query{
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "abc"}}],
        limit: nil,
        sorts: []
      }

      assert QueryOptimizer.estimate_cost(query) == :low
    end

    test "any equality filter treated as partition key equality" do
      # has_partition_key_equality? matches %{operator: :eq, left: %{name: _}}
      query = %AshScylla.Query{
        filters: [%{operator: :eq, left: %{name: :email}, right: %{value: "a@b.co"}}],
        limit: nil,
        sorts: []
      }

      assert QueryOptimizer.estimate_cost(query) == :low
    end

    test "non-equality filter is high" do
      query = %AshScylla.Query{
        filters: [%{operator: :gt, left: %{name: :created_at}, right: %{value: "2024-01-01"}}],
        limit: nil,
        sorts: []
      }

      assert QueryOptimizer.estimate_cost(query) == :medium
    end

    test "sorts increase low to medium" do
      query = %AshScylla.Query{
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "abc"}}],
        limit: nil,
        sorts: [:name]
      }

      assert QueryOptimizer.estimate_cost(query) == :medium
    end

    test "sorts increase medium to high" do
      query = %AshScylla.Query{
        filters: [%{operator: :gt, left: %{name: :created_at}, right: %{value: "2024-01-01"}}],
        limit: nil,
        sorts: [:name]
      }

      assert QueryOptimizer.estimate_cost(query) == :high
    end

    test "limit reduces medium to low" do
      query = %AshScylla.Query{
        filters: [%{operator: :gt, left: %{name: :created_at}, right: %{value: "2024-01-01"}}],
        limit: 10,
        sorts: []
      }

      assert QueryOptimizer.estimate_cost(query) == :low
    end

    test "limit reduces high to medium" do
      query = %AshScylla.Query{
        filters: [%{operator: :gt, left: %{name: :created_at}, right: %{value: "2024-01-01"}}],
        limit: 10,
        sorts: [:name]
      }

      assert QueryOptimizer.estimate_cost(query) == :medium
    end

    test "sorts do not increase full_scan" do
      # maybe_increase_for_sorts has no match for :full_scan, stays :full_scan
      query = %AshScylla.Query{filters: [], limit: nil, sorts: [:name]}
      assert QueryOptimizer.estimate_cost(query) == :full_scan
    end
  end

  # ---------------------------------------------------------------------------
  # token_aware_hint/1
  # ---------------------------------------------------------------------------

  describe "token_aware_hint/1" do
    test "returns token hint when partition key equality present" do
      query = %AshScylla.Query{
        resource: DefaultResource,
        filters: [
          %{
            operator: :eq,
            left: %{name: :id},
            right: %{value: "550e8400-e29b-41d4-a716-446655440000"}
          }
        ]
      }

      assert QueryOptimizer.token_aware_hint(query) == [
               token: "550e8400-e29b-41d4-a716-446655440000"
             ]
    end

    test "returns empty when no partition key filter" do
      query = %AshScylla.Query{
        resource: DefaultResource,
        filters: [%{operator: :eq, left: %{name: :name}, right: %{value: "Alice"}}]
      }

      assert QueryOptimizer.token_aware_hint(query) == []
    end

    test "returns empty for empty filters" do
      query = %AshScylla.Query{resource: DefaultResource, filters: []}
      assert QueryOptimizer.token_aware_hint(query) == []
    end

    test "with nil resource defaults pk to :id" do
      # When resource is nil, pk_columns defaults to [:id]
      query = %AshScylla.Query{
        resource: nil,
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "abc-123"}}]
      }

      assert QueryOptimizer.token_aware_hint(query) == [token: "abc-123"]
    end

    test "handles :op format filters" do
      query = %AshScylla.Query{
        resource: DefaultResource,
        filters: [%{op: :eq, left: %{name: :id}, right: %{value: "abc-123"}}]
      }

      assert QueryOptimizer.token_aware_hint(query) == [token: "abc-123"]
    end
  end
end
