defmodule AshScylla.QueryOptimizerCoverageTest do
  @moduledoc """
  Line-coverage tests for AshScylla.DataLayer.QueryOptimizer paths not hit by
  query_optimizer_test.exs: cost-estimation fallback branches, filter-shape
  predicates, profiling opt-out, speculative-retry warning, and token hint
  fallthrough.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshScylla.DataLayer.QueryOptimizer

  describe "optimize/2 remaining branches" do
    test "profiling false adds no key" do
      assert [] = QueryOptimizer.optimize(nil, profiling: false)
    end

    test "custom speculative retry without delay warns and omits the delay key" do
      log =
        capture_log(fn ->
          result = QueryOptimizer.optimize(nil, speculative_retry: :custom)

          assert [speculative_retry: :custom] = result
          refute Keyword.has_key?(result, :speculative_retry_delay_ms)
        end)

      assert log =~ "Speculative retry policy :custom set without"
    end
  end

  describe "optimal_page_size/1 filter shapes" do
    test "op-key equality filter counts as partition key filter" do
      query = %AshScylla.Query{
        filters: [%{op: :eq, left: %{name: :id}, right: %{value: "abc"}}],
        limit: nil
      }

      assert QueryOptimizer.optimal_page_size(query) == 50
    end

    test "non-equality filters skip the partition-key branch and land on indexed size" do
      query = %AshScylla.Query{
        filters: [%{operator: :gt, left: %{name: :created_at}, right: %{value: "z"}}],
        limit: nil
      }

      assert QueryOptimizer.optimal_page_size(query) == 100
    end
  end

  describe "estimate_cost/1 remaining branches" do
    test "range operator on a binary-named column is medium" do
      query = %AshScylla.Query{
        filters: [%{operator: :gt, left: %{name: "created_at"}, right: %{value: "z"}}],
        limit: nil,
        sorts: []
      }

      assert QueryOptimizer.estimate_cost(query) == :medium
    end

    test "op-key range filter is medium via the clustering-range check" do
      query = %AshScylla.Query{filters: [%{op: :gt}], limit: nil, sorts: []}
      assert QueryOptimizer.estimate_cost(query) == :medium
    end

    test "unrecognized filters fall back to high" do
      query = %AshScylla.Query{filters: [%{:foo => :bar}], limit: nil, sorts: []}
      assert QueryOptimizer.estimate_cost(query) == :high
    end

    test "high cost with a limit reduces to medium" do
      query = %AshScylla.Query{filters: [%{:foo => :bar}], limit: 10, sorts: []}
      assert QueryOptimizer.estimate_cost(query) == :medium
    end

    test "op-key equality filter is low" do
      query = %AshScylla.Query{
        filters: [%{op: :eq, left: %{name: :id}, right: %{value: "abc"}}],
        limit: nil,
        sorts: []
      }

      assert QueryOptimizer.estimate_cost(query) == :low
    end

    test "nil sorts leave the cost unchanged" do
      query = %AshScylla.Query{
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "abc"}}],
        limit: nil,
        sorts: nil
      }

      assert QueryOptimizer.estimate_cost(query) == :low
    end
  end

  describe "token_aware_hint/1 remaining branch" do
    test "filters without a wrapped value produce no hint" do
      query = %AshScylla.Query{
        resource: nil,
        filters: [%{operator: :eq, left: %{name: :id}, right: "raw-value"}]
      }

      assert QueryOptimizer.token_aware_hint(query) == []
    end
  end
end
