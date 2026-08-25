defmodule AshScylla.SecondaryIndexStructTest do
  @moduledoc """
  Regression tests for the `AshScylla.DataLayer.SecondaryIndex` struct
  refactor: every `secondary_index` DSL form must produce `%SecondaryIndex{}`
  structs (no ad-hoc maps), and the struct-driven consumers — migration CQL
  generation, index-scan detection, and filter validation — must keep working
  end-to-end.

  Also covers the new `AshScylla.Identifier.validate_uuid/1` helpers added
  alongside this change set.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Dsl
  alias AshScylla.DataLayer.SecondaryIndex
  alias AshScylla.Identifier
  alias AshScylla.TestResourceWithIndexes

  defmodule AllFormsResource do
    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, only: [scylla: 1]

    scylla do
      repo(AshScylla.TestRepo)
      table("si_all_forms")
      keyspace("struct_ks")

      secondary_index(:single)
      secondary_index([:left, :right])
      secondary_index({:tuple_form, [name: "idx_tuple"]})
      secondary_index(:two_arg, name: "idx_two_arg")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:single, :string, public?: true)
      attribute(:left, :string, public?: true)
      attribute(:right, :string, public?: true)
      attribute(:tuple_form, :string, public?: true)
      attribute(:two_arg, :string, public?: true)
    end
  end

  describe "SecondaryIndex.parse/1" do
    test "atom form yields a single-column index" do
      assert %SecondaryIndex{columns: [:email], name: nil, options: []} =
               SecondaryIndex.parse(:email)
    end

    test "list form preserves column order" do
      assert %SecondaryIndex{columns: [:name, :age], name: nil, options: []} =
               SecondaryIndex.parse([:name, :age])
    end

    test "tuple form captures custom names and raw options" do
      assert %SecondaryIndex{columns: [:status], name: "idx_status", options: [name: "idx_status"]} =
               SecondaryIndex.parse({:status, name: "idx_status"})
    end

    test "invalid input raises a configuration error" do
      assert_raise RuntimeError, ~r/Invalid secondary_index configuration/, fn ->
        SecondaryIndex.parse("not_a_column")
      end
    end
  end

  describe "effective_name/3" do
    test "falls back to the default table/column name" do
      idx = SecondaryIndex.parse(:email)

      assert SecondaryIndex.effective_name(idx, "users", :email) == "idx_users_email"
      assert SecondaryIndex.default_name("users", :email) == "idx_users_email"
    end

    test "namespaces custom-named indexes per column" do
      idx = SecondaryIndex.parse({:email, name: "custom"})

      assert SecondaryIndex.effective_name(idx, "users", :email) == "custom_email"
    end
  end

  describe "DSL integration" do
    test "every macro form compiles into %SecondaryIndex{} structs" do
      indexes = AllFormsResource.__ash_scylla__(:secondary_indexes)

      assert [%SecondaryIndex{}, %SecondaryIndex{}, %SecondaryIndex{}, %SecondaryIndex{}] =
               indexes

      # Module attributes accumulate in reverse declaration order.
      assert Enum.map(indexes, & &1.columns) == [
               [:two_arg],
               [:tuple_form],
               [:left, :right],
               [:single]
             ]

      assert Enum.at(indexes, 0).name == "idx_two_arg"
      assert Enum.at(indexes, 1).name == "idx_tuple"
      assert Enum.at(indexes, 2).name == nil
      assert Enum.at(indexes, 3).name == nil
    end

    test "Dsl.secondary_indexes/1 exposes the same structs" do
      assert Dsl.secondary_indexes(AllFormsResource) ==
               AllFormsResource.__ash_scylla__(:secondary_indexes)
    end

    test "has_secondary_index?/2 works off struct columns" do
      assert Dsl.has_secondary_index?(AllFormsResource, :right)
      refute Dsl.has_secondary_index?(AllFormsResource, :id)
    end
  end

  describe "migration CQL generation from structs" do
    test "create_secondary_indexes_cql honors custom struct names" do
      cql = AshScylla.Migration.create_secondary_indexes_cql(TestResourceWithIndexes)

      assert is_list(cql)
      # Custom struct names are honored verbatim.
      assert Enum.any?(cql, &(&1 =~ "CREATE INDEX IF NOT EXISTS idx_user_status"))
      # Default naming applies for unnamed struct indexes.
      assert Enum.any?(cql, &(&1 =~ "idx_test_users_email"))

      assert Enum.all?(cql, &String.starts_with?(&1, "CREATE INDEX IF NOT EXISTS"))
    end

    test "unindexable columns are skipped based on struct columns" do
      statements =
        AshScylla.Migration.secondary_index_statements(
          "events",
          [%SecondaryIndex{columns: [:id, :tenant], name: nil}],
          [:id]
        )

      assert length(statements) == 1
      assert hd(statements) =~ "idx_events_tenant"
      assert hd(statements) =~ ~s[("tenant")]
      refute hd(statements) =~ "(\"id\")"
    end
  end

  describe "query planning with struct indexes" do
    test "secondary_index_scan? detects filters on indexed columns only" do
      indexed_filter = %{left: %{name: :email}, right: %{value: "x"}}
      unindexed_filter = %{left: %{name: :content}, right: %{value: "x"}}

      assert AshScylla.DataLayer.QueryBuilder.secondary_index_scan?(
               TestResourceWithIndexes,
               [indexed_filter]
             )

      refute AshScylla.DataLayer.QueryBuilder.secondary_index_scan?(
               TestResourceWithIndexes,
               [unindexed_filter]
             )
    end
  end

  describe "Identifier.validate_uuid/1 and valid_uuid?/1" do
    test "accepts canonical uppercase UUIDs and downcases them" do
      upper = String.upcase(Ash.UUID.generate())

      assert {:ok, downcased} = Identifier.validate_uuid(upper)
      assert downcased == String.downcase(upper)
    end

    test "accepts canonical lowercase UUIDs unchanged" do
      uuid = Ash.UUID.generate()

      assert {:ok, ^uuid} = Identifier.validate_uuid(uuid)
      assert Identifier.valid_uuid?(uuid)
    end

    test "rejects malformed strings with a descriptive error" do
      assert {:error, message} = Identifier.validate_uuid("not-a-uuid")
      assert message =~ "Invalid UUID"
      assert message =~ "8-4-4-4-12"

      refute Identifier.valid_uuid?("12345")
      refute Identifier.valid_uuid?(String.replace(Ash.UUID.generate(), "-", ""))
    end

    test "rejects non-string values" do
      assert {:error, message} = Identifier.validate_uuid(123)
      assert message =~ "expected a string"
      assert message =~ "123"

      refute Identifier.valid_uuid?(:an_atom)
      refute Identifier.valid_uuid?(nil)
      refute Identifier.valid_uuid?([Ash.UUID.generate()])
    end
  end
end
