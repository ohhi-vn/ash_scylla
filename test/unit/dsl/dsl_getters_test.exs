defmodule AshScylla.DslGettersTest do
  @moduledoc """
  Comprehensive tests for all Dsl getter functions and complex DSL
  definitions. Covers every option in the `scylla` block macro and
  verifies that the public API getters return correct values.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.Dsl

  # ══════════════════════════════════════════════════════════════════════════
  # Inline test resources — individual DSL options
  # ══════════════════════════════════════════════════════════════════════════

  defmodule ResourceWithMigrateFalse do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("no_migrate_items")
      migrate(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read])
    end
  end

  defmodule ResourceWithMigrateTrue do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("migrate_items")
      migrate(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read])
    end
  end

  defmodule ResourceWithBaseFilter do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("bf_items")
      base_filter(is_active: true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:is_active, :boolean)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithBaseFilterComplex do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("bf_complex_items")
      base_filter(is_active: true, status: "active")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:is_active, :boolean)
      attribute(:status, :string)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithDefaultContext do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("dc_items")
      default_context(%{source: "test", env: "staging"})
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithDescription do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("desc_items")
      description("A test resource with a description")
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithMultipleIdentities do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("multi_identity_items")
      identity(:unique_email, [:email])
      identity(:unique_name, [:name])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:email, :string)
      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read])
    end
  end

  defmodule ResourceWithAggregate do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("agg_items")
      aggregate(:count_users, :count, :id)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithMultipleAggregates do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("multi_agg_items")
      aggregate(:count_users, :count, :id)
      aggregate(:sum_age, :sum, :age)
      aggregate(:min_age, :min, :age)
      aggregate(:max_age, :max, :age)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:age, :integer)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithCalculation do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("calc_items")
      calculation(:full_name, :string, :concat)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:email, :string)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithMultipleCalculations do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("multi_calc_items")
      calculation(:full_name, :string, :concat)
      calculation(:display_name, :string, :coalesce)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:email, :string)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithPreparation do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("prep_items")
      preparation(:some_preparation)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithMultiplePreparations do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("multi_prep_items")
      preparation(:prep_one)
      preparation(:prep_two)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithChange do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("chg_items")
      change(:some_change)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:create, :read])
    end
  end

  defmodule ResourceWithMultipleChanges do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("multi_chg_items")
      change(:chg_one)
      change(:chg_two)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:create, :read])
    end
  end

  defmodule ResourceWithValidation do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("val_items")
      validation(:some_validation)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:create, :read])
    end
  end

  defmodule ResourceWithMultipleValidations do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("multi_val_items")
      validation(:val_one)
      validation(:val_two)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:create, :read])
    end
  end

  defmodule ResourceWithPipeline do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("pipe_items")
      pipeline(:some_pipeline)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithMultiplePipelines do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("multi_pipe_items")
      pipeline(:pipe_one)
      pipeline(:pipe_two)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithMultitenancyContext do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("mt_context_items")
      multitenancy(strategy: :context, attribute: :tenant_id)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:tenant_id, :uuid)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithMultitenancyAttribute do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("mt_attr_items")
      multitenancy(strategy: :attribute, attribute: :org_id)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithCodeInterface do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("ci_items")
      code_interface(definitions: [create: :default, read: :default])
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:create, :read])
    end
  end

  defmodule ResourceWithBelongsTo do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("belongs_to_items")
      relationship(:belongs_to, :org, AshScylla.TestResource)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithHasMany do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("has_many_items")
      relationship(:has_many, :comments, AshScylla.TestResource)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithHasOne do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("has_one_items")
      relationship(:has_one, :profile, AshScylla.TestResource)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithManyToMany do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("m2m_items")
      relationship(:many_to_many, :tags, AshScylla.TestResource, through: AshScylla.TestResource)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithActionConfig do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("ac_items")
      action(:create, :custom_create, [])
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:create, :read])
    end
  end

  defmodule ResourceWithMultipleActionConfigs do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("multi_ac_items")
      action(:create, :custom_create, [])
      action(:read, :custom_read, [])
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:create, :read])
    end
  end

  defmodule ResourceWithMultipleMVs do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("multi_mv_items")
      materialized_view({:by_email, primary_key: [:email, :id]})
      materialized_view({:by_status, primary_key: [:status, :id]})
      materialized_view({:by_name, primary_key: [:name, :id]})
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:email, :string)
      attribute(:status, :string)
      attribute(:name, :string)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule ResourceWithPaginationOffset do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("offset_items")
      pagination(:offset)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Complex resource: all DSL 3.0 options combined
  # ══════════════════════════════════════════════════════════════════════════

  defmodule FullFeatureResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("full_feature_items")
      keyspace("ff_keyspace")
      consistency(:quorum)
      ttl(7200)
      lwt(true)
      pagination(:token)
      migrate(true)
      secondary_index(:email)
      secondary_index(:status, name: "idx_ff_status")
      secondary_index([:name, :category])
      materialized_view({:by_email, primary_key: [:email, :id]})
      materialized_view({:by_status, primary_key: [:status, :id]})
      identity(:unique_email, [:email])
      identity(:unique_name_category, [:name, :category])
      aggregate(:count_all, :count, :id)
      aggregate(:sum_age, :sum, :age)
      calculation(:display_name, :string, :coalesce)
      preparation(:prep_one)
      validation(:val_one)
      change(:chg_one)
      pipeline(:pipe_one)
      base_filter(is_active: true)
      default_context(%{env: "test"})
      description("Full-featured test resource")
      multitenancy(strategy: :context, attribute: :tenant_id)
      code_interface(definitions: [create: :default, read: :default])
      relationship(:belongs_to, :org, AshScylla.TestResource)
      relationship(:has_many, :comments, AshScylla.TestResource)
      action(:create, :custom_create, [])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:email, :string)
      attribute(:status, :string)
      attribute(:name, :string)
      attribute(:category, :string)
      attribute(:age, :integer)
      attribute(:is_active, :boolean)
      attribute(:tenant_id, :uuid)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: migrate/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.migrate?/1" do
    test "returns false when migrate false is configured" do
      assert Dsl.migrate?(ResourceWithMigrateFalse) == false
    end

    test "returns true when migrate true is configured" do
      assert Dsl.migrate?(ResourceWithMigrateTrue) == true
    end

    test "returns true when migrate is not configured (default)" do
      assert Dsl.migrate?(AshScylla.TestResource) == true
    end

    test "returns true for resource without ash_scylla config" do
      assert Dsl.migrate?(String) == true
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: base_filter/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.base_filter/1" do
    test "returns the configured base_filter" do
      assert Dsl.base_filter(ResourceWithBaseFilter) == [is_active: true]
    end

    test "returns complex base_filter with multiple conditions" do
      assert Dsl.base_filter(ResourceWithBaseFilterComplex) == [
               is_active: true,
               status: "active"
             ]
    end

    test "returns nil when base_filter is not configured" do
      assert Dsl.base_filter(AshScylla.TestResource) == nil
    end

    test "returns nil for resource without ash_scylla config" do
      assert Dsl.base_filter(String) == nil
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: default_context/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.default_context/1" do
    test "returns the configured default_context" do
      assert Dsl.default_context(ResourceWithDefaultContext) == %{source: "test", env: "staging"}
    end

    test "returns nil when default_context is not configured" do
      assert Dsl.default_context(AshScylla.TestResource) == nil
    end

    test "returns nil for resource without ash_scylla config" do
      assert Dsl.default_context(String) == nil
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: description/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.description/1" do
    test "returns the configured description" do
      assert Dsl.description(ResourceWithDescription) == "A test resource with a description"
    end

    test "returns nil when description is not configured" do
      assert Dsl.description(AshScylla.TestResource) == nil
    end

    test "returns nil for resource without ash_scylla config" do
      assert Dsl.description(String) == nil
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: identities/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.identities/1" do
    test "returns empty list when no identities are configured" do
      assert Dsl.identities(AshScylla.TestResource) == []
    end

    test "returns empty list for resource without ash_scylla config" do
      assert Dsl.identities(String) == []
    end

    test "returns single identity" do
      identities = Dsl.identities(ResourceWithMultipleIdentities)
      assert length(identities) == 2

      email_identity = Enum.find(identities, &(&1.name == :unique_email))
      assert email_identity != nil
      assert email_identity.columns == [:email]

      name_identity = Enum.find(identities, &(&1.name == :unique_name))
      assert name_identity != nil
      assert name_identity.columns == [:name]
    end

    test "returns identities with correct structure" do
      identities = Dsl.identities(ResourceWithMultipleIdentities)

      for identity <- identities do
        assert is_map(identity)
        assert Map.has_key?(identity, :name)
        assert Map.has_key?(identity, :columns)
        assert Map.has_key?(identity, :options)
        assert is_atom(identity.name)
        assert is_list(identity.columns)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: aggregates/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.aggregates/1" do
    test "returns empty list when no aggregates are configured" do
      assert Dsl.aggregates(AshScylla.TestResource) == []
    end

    test "returns empty list for resource without ash_scylla config" do
      assert Dsl.aggregates(String) == []
    end

    test "returns single aggregate" do
      aggregates = Dsl.aggregates(ResourceWithAggregate)
      assert length(aggregates) == 1
      agg = hd(aggregates)
      # The first argument is stored in :type, second in :name
      assert agg.type == :count_users
      assert agg.name == :count
      assert agg.field == :id
    end

    test "returns multiple aggregates" do
      aggregates = Dsl.aggregates(ResourceWithMultipleAggregates)
      assert length(aggregates) == 4

      names = Enum.map(aggregates, & &1.type)
      assert :count_users in names
      assert :sum_age in names
      assert :min_age in names
      assert :max_age in names
    end

    test "returns aggregates with correct structure" do
      aggregates = Dsl.aggregates(ResourceWithMultipleAggregates)

      for agg <- aggregates do
        assert is_map(agg)
        assert Map.has_key?(agg, :type)
        assert Map.has_key?(agg, :name)
        assert Map.has_key?(agg, :field)
        assert Map.has_key?(agg, :options)
        assert is_atom(agg.type)
        assert is_atom(agg.name)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: calculations/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.calculations/1" do
    test "returns empty list when no calculations are configured" do
      assert Dsl.calculations(AshScylla.TestResource) == []
    end

    test "returns empty list for resource without ash_scylla config" do
      assert Dsl.calculations(String) == []
    end

    test "returns single calculation" do
      calculations = Dsl.calculations(ResourceWithCalculation)
      assert length(calculations) == 1
      calc = hd(calculations)
      assert calc.name == :full_name
      assert calc.type == :string
    end

    test "returns multiple calculations" do
      calculations = Dsl.calculations(ResourceWithMultipleCalculations)
      assert length(calculations) == 2

      names = Enum.map(calculations, & &1.name)
      assert :full_name in names
      assert :display_name in names
    end

    test "returns calculations with correct structure" do
      calculations = Dsl.calculations(ResourceWithMultipleCalculations)

      for calc <- calculations do
        assert is_map(calc)
        assert Map.has_key?(calc, :name)
        assert Map.has_key?(calc, :type)
        assert Map.has_key?(calc, :expression)
        assert Map.has_key?(calc, :options)
        assert is_atom(calc.name)
        assert is_atom(calc.type)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: preparations/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.preparations/1" do
    test "returns empty list when no preparations are configured" do
      assert Dsl.preparations(AshScylla.TestResource) == []
    end

    test "returns empty list for resource without ash_scylla config" do
      assert Dsl.preparations(String) == []
    end

    test "returns single preparation" do
      preparations = Dsl.preparations(ResourceWithPreparation)
      assert length(preparations) == 1
      prep = hd(preparations)
      assert prep.preparation == :some_preparation
    end

    test "returns multiple preparations" do
      preparations = Dsl.preparations(ResourceWithMultiplePreparations)
      assert length(preparations) == 2
    end

    test "returns preparations with correct structure" do
      preparations = Dsl.preparations(ResourceWithMultiplePreparations)

      for prep <- preparations do
        assert is_map(prep)
        assert Map.has_key?(prep, :preparation)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: changes/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.changes/1" do
    test "returns empty list when no changes are configured" do
      assert Dsl.changes(AshScylla.TestResource) == []
    end

    test "returns empty list for resource without ash_scylla config" do
      assert Dsl.changes(String) == []
    end

    test "returns single change" do
      changes = Dsl.changes(ResourceWithChange)
      assert length(changes) == 1
      chg = hd(changes)
      assert chg.change == :some_change
    end

    test "returns multiple changes" do
      changes = Dsl.changes(ResourceWithMultipleChanges)
      assert length(changes) == 2
    end

    test "returns changes with correct structure" do
      changes = Dsl.changes(ResourceWithMultipleChanges)

      for chg <- changes do
        assert is_map(chg)
        assert Map.has_key?(chg, :change)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: validations/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.validations/1" do
    test "returns empty list when no validations are configured" do
      assert Dsl.validations(AshScylla.TestResource) == []
    end

    test "returns empty list for resource without ash_scylla config" do
      assert Dsl.validations(String) == []
    end

    test "returns single validation" do
      validations = Dsl.validations(ResourceWithValidation)
      assert length(validations) == 1
      val = hd(validations)
      assert val.validation == :some_validation
    end

    test "returns multiple validations" do
      validations = Dsl.validations(ResourceWithMultipleValidations)
      assert length(validations) == 2
    end

    test "returns validations with correct structure" do
      validations = Dsl.validations(ResourceWithMultipleValidations)

      for val <- validations do
        assert is_map(val)
        assert Map.has_key?(val, :validation)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: pipelines/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.pipelines/1" do
    test "returns empty list when no pipelines are configured" do
      assert Dsl.pipelines(AshScylla.TestResource) == []
    end

    test "returns empty list for resource without ash_scylla config" do
      assert Dsl.pipelines(String) == []
    end

    test "returns single pipeline" do
      pipelines = Dsl.pipelines(ResourceWithPipeline)
      assert length(pipelines) == 1
      pipe = hd(pipelines)
      assert pipe.pipeline == :some_pipeline
    end

    test "returns multiple pipelines" do
      pipelines = Dsl.pipelines(ResourceWithMultiplePipelines)
      assert length(pipelines) == 2
    end

    test "returns pipelines with correct structure" do
      pipelines = Dsl.pipelines(ResourceWithMultiplePipelines)

      for pipe <- pipelines do
        assert is_map(pipe)
        assert Map.has_key?(pipe, :pipeline)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: multitenancy/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.multitenancy/1" do
    test "returns nil when multitenancy is not configured" do
      assert Dsl.multitenancy(AshScylla.TestResource) == nil
    end

    test "returns nil for resource without ash_scylla config" do
      assert Dsl.multitenancy(String) == nil
    end

    test "returns context strategy config" do
      mt = Dsl.multitenancy(ResourceWithMultitenancyContext)
      assert mt != nil
      assert mt.strategy == :context
      assert mt.attribute == :tenant_id
    end

    test "returns attribute strategy config" do
      mt = Dsl.multitenancy(ResourceWithMultitenancyAttribute)
      assert mt != nil
      assert mt.strategy == :attribute
      assert mt.attribute == :org_id
    end

    test "returns a map with :strategy and :attribute keys" do
      mt = Dsl.multitenancy(ResourceWithMultitenancyContext)
      assert is_map(mt)
      assert Map.has_key?(mt, :strategy)
      assert Map.has_key?(mt, :attribute)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: scylla_code_interface/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.scylla_code_interface/1" do
    test "returns nil when code_interface is not configured" do
      assert Dsl.scylla_code_interface(AshScylla.TestResource) == nil
    end

    test "returns nil for resource without ash_scylla config" do
      assert Dsl.scylla_code_interface(String) == nil
    end

    test "returns the configured code_interface" do
      ci = Dsl.scylla_code_interface(ResourceWithCodeInterface)
      assert ci != nil
      assert is_map(ci)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: relationships/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.relationships/1" do
    test "returns empty list when no relationships are configured" do
      assert Dsl.relationships(AshScylla.TestResource) == []
    end

    test "returns empty list for resource without ash_scylla config" do
      assert Dsl.relationships(String) == []
    end

    test "returns belongs_to relationship" do
      rels = Dsl.relationships(ResourceWithBelongsTo)
      assert length(rels) == 1
      rel = hd(rels)
      assert rel.type == :belongs_to
      assert rel.name == :org
      assert rel.target == AshScylla.TestResource
    end

    test "returns has_many relationship" do
      rels = Dsl.relationships(ResourceWithHasMany)
      assert length(rels) == 1
      rel = hd(rels)
      assert rel.type == :has_many
      assert rel.name == :comments
      assert rel.target == AshScylla.TestResource
    end

    test "returns has_one relationship" do
      rels = Dsl.relationships(ResourceWithHasOne)
      assert length(rels) == 1
      rel = hd(rels)
      assert rel.type == :has_one
      assert rel.name == :profile
      assert rel.target == AshScylla.TestResource
    end

    test "returns many_to_many relationship" do
      rels = Dsl.relationships(ResourceWithManyToMany)
      assert length(rels) == 1
      rel = hd(rels)
      assert rel.type == :many_to_many
      assert rel.name == :tags
      assert rel.target == AshScylla.TestResource
    end

    test "returns relationships with correct structure" do
      rels = Dsl.relationships(ResourceWithBelongsTo)

      for rel <- rels do
        assert is_map(rel)
        assert Map.has_key?(rel, :type)
        assert Map.has_key?(rel, :name)
        assert Map.has_key?(rel, :target)
        assert Map.has_key?(rel, :options)
        assert is_atom(rel.type)
        assert is_atom(rel.name)
        assert is_atom(rel.target)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: action_configs/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.action_configs/1" do
    test "returns empty list when no action configs are configured" do
      assert Dsl.action_configs(AshScylla.TestResource) == []
    end

    test "returns empty list for resource without ash_scylla config" do
      assert Dsl.action_configs(String) == []
    end

    test "returns single action config" do
      action_configs = Dsl.action_configs(ResourceWithActionConfig)
      assert length(action_configs) == 1
      ac = hd(action_configs)
      assert ac.type == :create
      assert ac.name == :custom_create
    end

    test "returns multiple action configs" do
      action_configs = Dsl.action_configs(ResourceWithMultipleActionConfigs)
      assert length(action_configs) == 2

      types = Enum.map(action_configs, & &1.type)
      assert :create in types
      assert :read in types
    end

    test "returns action configs with correct structure" do
      action_configs = Dsl.action_configs(ResourceWithMultipleActionConfigs)

      for ac <- action_configs do
        assert is_map(ac)
        assert Map.has_key?(ac, :type)
        assert Map.has_key?(ac, :name)
        assert Map.has_key?(ac, :options)
        assert is_atom(ac.type)
        assert is_atom(ac.name)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: materialized_views/1 with multiple views
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.materialized_views/1 with multiple views" do
    test "returns multiple materialized views" do
      views = Dsl.materialized_views(ResourceWithMultipleMVs)
      assert length(views) == 3

      names = Enum.map(views, & &1.name)
      assert :by_email in names
      assert :by_status in names
      assert :by_name in names
    end

    test "returns materialized views with correct structure" do
      views = Dsl.materialized_views(ResourceWithMultipleMVs)

      for view <- views do
        assert is_map(view)
        assert Map.has_key?(view, :name)
        assert Map.has_key?(view, :config)
        assert is_atom(view.name)
        assert is_list(view.config)
      end
    end

    test "returns correct primary_key config for each view" do
      views = Dsl.materialized_views(ResourceWithMultipleMVs)

      by_email = Enum.find(views, &(&1.name == :by_email))
      assert by_email.config == [primary_key: [:email, :id]]

      by_status = Enum.find(views, &(&1.name == :by_status))
      assert by_status.config == [primary_key: [:status, :id]]

      by_name = Enum.find(views, &(&1.name == :by_name))
      assert by_name.config == [primary_key: [:name, :id]]
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: pagination/1 with :offset
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dsl.pagination/1 with :offset" do
    test "returns :offset when pagination :offset is configured" do
      assert Dsl.pagination(ResourceWithPaginationOffset) == :offset
    end

    test "returns :token for resource without pagination config" do
      assert Dsl.pagination(AshScylla.TestResource) == :token
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: FullFeatureResource — all getters
  # ══════════════════════════════════════════════════════════════════════════

  describe "FullFeatureResource: all getters" do
    test "table returns configured table" do
      assert Dsl.table(FullFeatureResource) == "full_feature_items"
    end

    test "repo returns configured repo" do
      assert Dsl.repo(FullFeatureResource) == AshScylla.TestRepo
    end

    test "keyspace returns configured keyspace" do
      assert Dsl.keyspace(FullFeatureResource) == "ff_keyspace"
    end

    test "consistency returns configured consistency" do
      assert Dsl.consistency(FullFeatureResource) == :quorum
    end

    test "ttl returns configured ttl" do
      assert Dsl.ttl(FullFeatureResource) == 7200
    end

    test "lwt returns configured lwt" do
      assert Dsl.lwt(FullFeatureResource) == true
    end

    test "pagination returns configured pagination" do
      assert Dsl.pagination(FullFeatureResource) == :token
    end

    test "migrate? returns configured migrate" do
      assert Dsl.migrate?(FullFeatureResource) == true
    end

    test "base_filter returns configured base_filter" do
      assert Dsl.base_filter(FullFeatureResource) == [is_active: true]
    end

    test "default_context returns configured default_context" do
      assert Dsl.default_context(FullFeatureResource) == %{env: "test"}
    end

    test "description returns configured description" do
      assert Dsl.description(FullFeatureResource) == "Full-featured test resource"
    end

    test "secondary_indexes returns all 3 indexes" do
      indexes = Dsl.secondary_indexes(FullFeatureResource)
      assert length(indexes) == 3
    end

    test "materialized_views returns both views" do
      views = Dsl.materialized_views(FullFeatureResource)
      assert length(views) == 2
    end

    test "identities returns both identities" do
      identities = Dsl.identities(FullFeatureResource)
      assert length(identities) == 2
    end

    test "aggregates returns both aggregates" do
      aggregates = Dsl.aggregates(FullFeatureResource)
      assert length(aggregates) == 2
    end

    test "calculations returns the calculation" do
      calculations = Dsl.calculations(FullFeatureResource)
      assert length(calculations) == 1
    end

    test "preparations returns the preparation" do
      preparations = Dsl.preparations(FullFeatureResource)
      assert length(preparations) == 1
    end

    test "validations returns the validation" do
      validations = Dsl.validations(FullFeatureResource)
      assert length(validations) == 1
    end

    test "changes returns the change" do
      changes = Dsl.changes(FullFeatureResource)
      assert length(changes) == 1
    end

    test "pipelines returns the pipeline" do
      pipelines = Dsl.pipelines(FullFeatureResource)
      assert length(pipelines) == 1
    end

    test "multitenancy returns context strategy" do
      mt = Dsl.multitenancy(FullFeatureResource)
      assert mt.strategy == :context
      assert mt.attribute == :tenant_id
    end

    test "scylla_code_interface returns config" do
      ci = Dsl.scylla_code_interface(FullFeatureResource)
      assert ci != nil
    end

    test "relationships returns belongs_to and has_many" do
      rels = Dsl.relationships(FullFeatureResource)
      assert length(rels) == 2

      types = Enum.map(rels, & &1.type)
      assert :belongs_to in types
      assert :has_many in types
    end

    test "action_configs returns custom action" do
      action_configs = Dsl.action_configs(FullFeatureResource)
      assert length(action_configs) == 1
      assert hd(action_configs).name == :custom_create
    end

    test "has_secondary_index? works correctly" do
      assert Dsl.has_secondary_index?(FullFeatureResource, :email) == true
      assert Dsl.has_secondary_index?(FullFeatureResource, :status) == true
      assert Dsl.has_secondary_index?(FullFeatureResource, :name) == true
      assert Dsl.has_secondary_index?(FullFeatureResource, :nonexistent) == false
    end

    test "per_action_consistency returns empty map (not configured)" do
      assert Dsl.per_action_consistency(FullFeatureResource) == %{}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: __ash_scylla__ callbacks for FullFeatureResource
  # ══════════════════════════════════════════════════════════════════════════

  describe "FullFeatureResource: __ash_scylla__ callbacks" do
    test "returns correct table" do
      assert FullFeatureResource.__ash_scylla__(:table) == "full_feature_items"
    end

    test "returns correct repo" do
      assert FullFeatureResource.__ash_scylla__(:repo) == AshScylla.TestRepo
    end

    test "returns correct keyspace" do
      assert FullFeatureResource.__ash_scylla__(:keyspace) == "ff_keyspace"
    end

    test "returns correct consistency" do
      assert FullFeatureResource.__ash_scylla__(:consistency) == :quorum
    end

    test "returns correct ttl" do
      assert FullFeatureResource.__ash_scylla__(:ttl) == 7200
    end

    test "returns correct lwt" do
      assert FullFeatureResource.__ash_scylla__(:lwt) == true
    end

    test "returns correct pagination" do
      assert FullFeatureResource.__ash_scylla__(:pagination) == :token
    end

    test "returns correct migrate" do
      assert FullFeatureResource.__ash_scylla__(:migrate) == true
    end

    test "returns correct base_filter" do
      assert FullFeatureResource.__ash_scylla__(:base_filter) == [is_active: true]
    end

    test "returns correct default_context" do
      assert FullFeatureResource.__ash_scylla__(:default_context) == %{env: "test"}
    end

    test "returns correct description" do
      assert FullFeatureResource.__ash_scylla__(:description) == "Full-featured test resource"
    end

    test "returns correct secondary_indexes" do
      indexes = FullFeatureResource.__ash_scylla__(:secondary_indexes)
      assert length(indexes) == 3
    end

    test "returns correct materialized_views" do
      views = FullFeatureResource.__ash_scylla__(:materialized_views)
      assert length(views) == 2
    end

    test "returns correct identities" do
      identities = FullFeatureResource.__ash_scylla__(:identities)
      assert length(identities) == 2
    end

    test "returns correct aggregates" do
      aggregates = FullFeatureResource.__ash_scylla__(:aggregates)
      assert length(aggregates) == 2
    end

    test "returns correct calculations" do
      calculations = FullFeatureResource.__ash_scylla__(:calculations)
      assert length(calculations) == 1
    end

    test "returns correct preparations" do
      preparations = FullFeatureResource.__ash_scylla__(:preparations)
      assert length(preparations) == 1
    end

    test "returns correct changes" do
      changes = FullFeatureResource.__ash_scylla__(:changes)
      assert length(changes) == 1
    end

    test "returns correct validations" do
      validations = FullFeatureResource.__ash_scylla__(:validations)
      assert length(validations) == 1
    end

    test "returns correct pipelines" do
      pipelines = FullFeatureResource.__ash_scylla__(:pipelines)
      assert length(pipelines) == 1
    end

    test "returns correct multitenancy" do
      mt = FullFeatureResource.__ash_scylla__(:multitenancy)
      assert mt.strategy == :context
    end

    test "returns correct relationships" do
      rels = FullFeatureResource.__ash_scylla__(:relationships)
      assert length(rels) == 2
    end

    test "returns correct action_configs" do
      action_configs = FullFeatureResource.__ash_scylla__(:action_configs)
      assert length(action_configs) == 1
    end

    test "returns nil for unknown key" do
      assert FullFeatureResource.__ash_scylla__(:unknown_key) == nil
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Tests: DataLayer integration with complex DSL
  # ══════════════════════════════════════════════════════════════════════════

  describe "DataLayer integration: complex DSL resource" do
    test "resource_to_query builds correct query for FullFeatureResource" do
      query = DataLayer.resource_to_query(FullFeatureResource, nil)
      assert %AshScylla.Query{} = query
      assert query.resource == FullFeatureResource
      assert query.repo == AshScylla.TestRepo
      assert query.table == "full_feature_items"
    end

    test "source/1 resolves table from FullFeatureResource" do
      assert DataLayer.source(FullFeatureResource) == "full_feature_items"
    end

    test "can? returns true for supported features on FullFeatureResource" do
      assert DataLayer.can?(FullFeatureResource, :create) == true
      assert DataLayer.can?(FullFeatureResource, :read) == true
      assert DataLayer.can?(FullFeatureResource, :update) == true
      assert DataLayer.can?(FullFeatureResource, :destroy) == true
      assert DataLayer.can?(FullFeatureResource, :filter) == true
      assert DataLayer.can?(FullFeatureResource, :limit) == true
      assert DataLayer.can?(FullFeatureResource, :select) == true
      assert DataLayer.can?(FullFeatureResource, :multitenancy) == true
      assert DataLayer.can?(FullFeatureResource, :bulk_create) == true
      assert DataLayer.can?(FullFeatureResource, :upsert) == true
      assert DataLayer.can?(FullFeatureResource, :keyset) == true
      assert DataLayer.can?(FullFeatureResource, :boolean_filter) == true
      assert DataLayer.can?(FullFeatureResource, :distinct) == true
    end

    test "can? returns false for unsupported features" do
      assert DataLayer.can?(FullFeatureResource, :offset) == false
      assert DataLayer.can?(FullFeatureResource, :expression_calculation) == false
      assert DataLayer.can?(FullFeatureResource, :lateral_join) == false
      assert DataLayer.can?(FullFeatureResource, :lock) == false
    end
  end
end
