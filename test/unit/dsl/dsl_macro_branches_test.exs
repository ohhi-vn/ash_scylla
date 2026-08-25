defmodule AshScylla.DslMacroBranchesTest do
  @moduledoc """
  Covers AshScylla.DataLayer.Dsl macro transformation branches for alternative
  argument shapes of scylla-block entries.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Dsl

  defmodule FvxSecondaryIndexKeywordForm do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      table("fvx_kw_index")
      secondary_index({:email, [name: "idx_fvx_email"]})
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:email, :string)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule FvxIdentityWithOpts do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      table("fvx_identity_opts")
      identity(:unique_email, [:email], unique: true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:email, :string)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule FvxAggregateArgForms do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      table("fvx_agg_forms")
      aggregate(:count, :total_count)
      aggregate(:sum, :total_age, field: :age)
      aggregate(:avg, :avg_score, {:score, []})
      aggregate(:max, :max_age, :age)
      aggregate(:min, :min_odd, 123)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:age, :integer)
      attribute(:score, :integer)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule FvxCalculationOptForms do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      table("fvx_calc_forms")
      calculation(:shouty, :string, "shouty_expr", private?: true)
      calculation(:plain, :string, "plain_expr", :junk_arg)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule FvxRelationshipJunkOpts do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      table("fvx_rel_junk")
      relationship(:belongs_to, :org, AshScylla.TestRepo, :not_a_list)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule FvxActionConfigForms do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      table("fvx_action_forms")
      action(:create, :bare_create)
      action(:update, :junk_update, :still_not_a_list)
      action(:read, :paged_read, pagination: [offset?: true])
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule FvxGetConfigRaisingResource do
    @moduledoc false

    def __ash_scylla__(:table), do: "only_table"
  end

  describe "secondary_index keyword-argument form" do
    test "parses {column, opts} tuple form" do
      indexes = Dsl.secondary_indexes(FvxSecondaryIndexKeywordForm)

      assert [%{columns: [:email], name: "idx_fvx_email"}] = indexes
    end
  end

  describe "identity with options" do
    test "stores columns and options" do
      identities = Dsl.identities(FvxIdentityWithOpts)

      assert [%{name: :unique_email, columns: [:email], options: [unique: true]}] = identities
    end

    test "raises when columns are not a list" do
      source = """
      defmodule FvxIdentityBad#{System.unique_integer([:positive])} do
        import AshScylla.DataLayer.Dsl

        scylla do
          identity :bad_identity, :not_a_list
        end
      end
      """

      assert_raise RuntimeError, ~r/identity requires columns list/, fn ->
        Code.compile_string(source)
      end
    end
  end

  describe "aggregate argument forms" do
    test "records type/name/field/options per form" do
      aggregates = Dsl.aggregates(FvxAggregateArgForms)

      assert %{
               type: :count,
               name: :total_count,
               field: nil,
               options: []
             } = Enum.find(aggregates, &(&1.name == :total_count))

      assert %{type: :sum, name: :total_age, field: nil, options: [field: :age]} =
               Enum.find(aggregates, &(&1.name == :total_age))

      assert %{type: :avg, name: :avg_score, field: :score, options: []} =
               Enum.find(aggregates, &(&1.name == :avg_score))

      assert %{type: :max, name: :max_age, field: :age, options: []} =
               Enum.find(aggregates, &(&1.name == :max_age))

      assert %{type: :min, name: :min_odd, field: nil, options: []} =
               Enum.find(aggregates, &(&1.name == :min_odd))
    end
  end

  describe "calculation option forms" do
    test "records expression with opts list or junk arg" do
      calculations = Dsl.calculations(FvxCalculationOptForms)

      assert %{name: :shouty, options: [private?: true]} =
               Enum.find(calculations, &(&1.name == :shouty))

      assert %{name: :plain, options: []} = Enum.find(calculations, &(&1.name == :plain))
    end
  end

  describe "relationship junk option form" do
    test "falls back to empty options" do
      relationships = Dsl.relationships(FvxRelationshipJunkOpts)

      assert [
               %{
                 type: :belongs_to,
                 name: :org,
                 target: AshScylla.TestRepo,
                 options: []
               }
             ] = relationships
    end
  end

  describe "action config argument forms" do
    test "records bare, junk-arg, and keyword action configs" do
      configs = Dsl.action_configs(FvxActionConfigForms)

      assert %{type: :create, name: :bare_create, options: []} =
               Enum.find(configs, &(&1.name == :bare_create))

      assert %{type: :update, name: :junk_update, options: []} =
               Enum.find(configs, &(&1.name == :junk_update))

      assert %{type: :read, name: :paged_read, options: [pagination: [offset?: true]]} =
               Enum.find(configs, &(&1.name == :paged_read))
    end
  end

  describe "get_config error handling" do
    test "returns default on FunctionClauseError from __ash_scylla__/1" do
      assert Dsl.table(FvxGetConfigRaisingResource) == "only_table"
      assert Dsl.keyspace(FvxGetConfigRaisingResource) == nil
    end

    test "returns default when resource does not export __ash_scylla__/1" do
      assert Dsl.pagination(NotAModule) == :token
    end
  end

  describe "compile-time validation errors" do
    test "materialized_view without a name raises" do
      source = """
      defmodule FvxMvBad#{System.unique_integer([:positive])} do
        import AshScylla.DataLayer.Dsl

        scylla do
          materialized_view primary_key: [:id]
        end
      end
      """

      assert_raise RuntimeError, ~r/materialized_view requires a name/, fn ->
        Code.compile_string(source)
      end
    end

    test "invalid pagination mode raises ArgumentError" do
      source = """
      defmodule FvxBadPagination#{System.unique_integer([:positive])} do
        import AshScylla.DataLayer.Dsl

        scylla do
          pagination :bogus_mode
        end
      end
      """

      assert_raise ArgumentError, ~r/Invalid pagination mode/, fn ->
        Code.compile_string(source)
      end
    end
  end
end
