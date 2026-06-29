defmodule AshScylla.SourceCacheTest do
  @moduledoc """
  Tests for the source/1 process dictionary cache.
  Covers: Issue #4 (Process dictionary cache in DataLayer.source/1 is not process-safe)
  """

  use ExUnit.Case, async: true

  defmodule CacheTestResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(AshScylla.TestRepo)
      table("cache_test_table")
      keyspace("ash_scylla_test")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read])
    end
  end

  describe "source/1 — table name resolution" do
    test "returns the configured table name" do
      result = AshScylla.DataLayer.source(CacheTestResource)
      assert result == "cache_test_table"
    end

    test "returns consistent result on repeated calls" do
      result1 = AshScylla.DataLayer.source(CacheTestResource)
      result2 = AshScylla.DataLayer.source(CacheTestResource)
      assert result1 == result2
    end
  end

  describe "resolve_table_name/1" do
    test "uses DSL table when configured" do
      result = AshScylla.DataLayer.resolve_table_name(CacheTestResource)
      assert result == "cache_test_table"
    end

    test "falls back to module name when no DSL table" do
      # TestResourceWithoutDSL would use its module name
      defmodule NoDslTableResource do
        @moduledoc false

        use Ash.Resource,
          domain: nil,
          data_layer: AshScylla.DataLayer

        attributes do
          uuid_primary_key(:id)
        end

        actions do
          defaults([:create])
        end
      end

      result = AshScylla.DataLayer.resolve_table_name(NoDslTableResource)
      assert result == "no_dsl_table_resource"
    end
  end
end
