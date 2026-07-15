defmodule AshScylla.DslVerifierTest do
  @moduledoc """
  Tests for DSL verifier behaviour using Spark.Test helpers.

  Verifier errors raised inside Spark's `@after_verify` hook are caught by the
  framework and emitted as stderr warnings. `Spark.Test` turns them back into
  structured data that tests can pattern-match on.

  See: https://spark.hexdocs.pm/test-spark-verifiers.html
  """

  use ExUnit.Case, async: true

  import Spark.Test

  # ---------------------------------------------------------------------------
  # Happy-path: valid DSL compiles without verifier errors
  # ---------------------------------------------------------------------------

  describe "valid DSL produces no verifier errors" do
    test "minimal valid resource compiles cleanly" do
      refute_dsl_errors do
        defmodule Elixir.ValidMinimalResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("valid_table")
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end

    test "full-config resource compiles cleanly" do
      refute_dsl_errors do
        defmodule Elixir.ValidFullConfigResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("full_config_table")
            keyspace("test_ks")
            consistency(:quorum)
            ttl(3600)
            pagination(:token)
            lwt(true)
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:email, :string)
          end

          actions do
            defaults([:create, :read, :update, :destroy])
          end
        end
      end
    end

    test "resource with secondary indexes compiles cleanly" do
      refute_dsl_errors do
        defmodule Elixir.ValidIndexedResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("indexed_table")
            secondary_index(:email)
            secondary_index([:name, :age])
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:email, :string)
            attribute(:name, :string)
            attribute(:age, :integer)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end

    test "resource with materialized view compiles cleanly" do
      refute_dsl_errors do
        defmodule Elixir.ValidMvResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("mv_table")
            materialized_view({:by_email, primary_key: [:email, :id]})
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:email, :string)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end

    test "resource with per_action_consistency compiles cleanly" do
      refute_dsl_errors do
        defmodule Elixir.ValidConsistencyResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("consistency_table")
            per_action_consistency(read: :one, create: :quorum, update: :local_quorum)
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:create, :read, :update])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: DSL with only Ash.Resource (no scylla block)
  # ---------------------------------------------------------------------------

  describe "resource without scylla block" do
    test "compiles without verifier errors" do
      refute_dsl_errors do
        defmodule Elixir.BareAshResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          attributes do
            uuid_primary_key(:id)
            attribute(:name, :string)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: DSL with multitenancy
  # ---------------------------------------------------------------------------

  describe "resource with multitenancy" do
    test "compiles cleanly with context strategy" do
      refute_dsl_errors do
        defmodule Elixir.MultitenancyContextResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("mt_table")
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
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: DSL with identities
  # ---------------------------------------------------------------------------

  describe "resource with identities" do
    test "compiles cleanly with identity" do
      refute_dsl_errors do
        defmodule Elixir.IdentityResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("identity_table")
            identity(:unique_email, [:email])
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:email, :string)
          end

          actions do
            defaults([:create, :read])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: DSL with aggregates and calculations
  # ---------------------------------------------------------------------------

  describe "resource with aggregates and calculations" do
    test "compiles cleanly with aggregates" do
      refute_dsl_errors do
        defmodule Elixir.AggregateResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("agg_table")
            aggregate(:count_users, :count, :id)
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: DSL with base_filter
  # ---------------------------------------------------------------------------

  describe "resource with base_filter" do
    test "compiles cleanly with base_filter" do
      refute_dsl_errors do
        defmodule Elixir.BaseFilterResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("bf_table")
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
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: DSL with preparations
  # ---------------------------------------------------------------------------

  describe "resource with preparations" do
    test "compiles cleanly with preparation" do
      refute_dsl_errors do
        defmodule Elixir.PreparationResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("prep_table")
            preparation(AshScylla.Preparations.DefaultPreparation)
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: DSL with validations
  # ---------------------------------------------------------------------------

  describe "resource with validations" do
    test "compiles cleanly with validation" do
      refute_dsl_errors do
        defmodule Elixir.ValidationResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("val_table")
            validation(AshScylla.Validations.DefaultValidation)
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:create, :read])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: DSL with changes
  # ---------------------------------------------------------------------------

  describe "resource with changes" do
    test "compiles cleanly with change" do
      refute_dsl_errors do
        defmodule Elixir.ChangeResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("chg_table")
            change(AshScylla.Changes.DefaultChange)
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:create, :read])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: DSL with code_interface
  # ---------------------------------------------------------------------------

  describe "resource with code_interface" do
    test "compiles cleanly with code_interface" do
      refute_dsl_errors do
        defmodule Elixir.CodeInterfaceResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("ci_table")
            code_interface(definitions: [create: :default, read: :default])
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:create, :read])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: DSL with action configs
  # ---------------------------------------------------------------------------

  describe "resource with action configs" do
    test "compiles cleanly with action config" do
      refute_dsl_errors do
        defmodule Elixir.ActionConfigResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("ac_table")
            action(:create, :custom_create, [])
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:create, :read])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: DSL with default_context
  # ---------------------------------------------------------------------------

  describe "resource with default_context" do
    test "compiles cleanly with default_context" do
      refute_dsl_errors do
        defmodule Elixir.DefaultContextResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("dc_table")
            default_context(%{source: "test"})
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: DSL with description
  # ---------------------------------------------------------------------------

  describe "resource with description" do
    test "compiles cleanly with description" do
      refute_dsl_errors do
        defmodule Elixir.DescriptionResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("desc_table")
            description("A test resource for verifier testing")
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: DSL with pipelines
  # ---------------------------------------------------------------------------

  describe "resource with pipelines" do
    test "compiles cleanly with pipeline" do
      refute_dsl_errors do
        defmodule Elixir.PipelineResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("pipe_table")
            pipeline(AshScylla.Pipelines.DefaultPipeline)
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: empty scylla block
  # ---------------------------------------------------------------------------

  describe "empty scylla block" do
    test "compiles cleanly with empty block" do
      refute_dsl_errors do
        defmodule Elixir.EmptyBlockResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: multiple resources in the same test block
  # ---------------------------------------------------------------------------

  describe "multiple resources in same test" do
    test "both compile cleanly when defined together" do
      refute_dsl_errors do
        defmodule Elixir.MultiResourceA do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("multi_a_table")
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end
        end

        defmodule Elixir.MultiResourceB do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("multi_b_table")
            secondary_index(:email)
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:email, :string)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: resource with all DSL options combined
  # ---------------------------------------------------------------------------

  describe "resource with all DSL options" do
    test "compiles cleanly with all options" do
      refute_dsl_errors do
        defmodule Elixir.AllOptionsResource do
          use Ash.Resource,
            domain: nil,
            data_layer: AshScylla.DataLayer

          import AshScylla.DataLayer.Dsl

          scylla do
            table("all_opts_table")
            keyspace("all_opts_ks")
            consistency(:quorum)
            ttl(7200)
            pagination(:token)
            lwt(true)
            secondary_index(:email)
            materialized_view({:by_status, primary_key: [:status, :id]})
            identity(:unique_email, [:email])
            aggregate(:count_all, :count, :id)
            per_action_consistency(read: :one, create: :quorum)
            base_filter(is_active: true)
            default_context(%{env: "test"})
            description("Resource with all DSL options")
            multitenancy(strategy: :context, attribute: :tenant_id)
            code_interface(definitions: [create: :default, read: :default])
            preparation(AshScylla.Preparations.DefaultPreparation)
            validation(AshScylla.Validations.DefaultValidation)
            change(AshScylla.Changes.DefaultChange)
            pipeline(AshScylla.Pipelines.DefaultPipeline)
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:email, :string)
            attribute(:status, :atom)
            attribute(:is_active, :boolean)
            attribute(:tenant_id, :uuid)
          end

          actions do
            defaults([:create, :read, :update, :destroy])
          end
        end
      end
    end
  end
end
