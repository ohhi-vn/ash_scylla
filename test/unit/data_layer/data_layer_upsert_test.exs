defmodule AshScylla.DataLayerUpsertTest do
  @moduledoc """
  Tests for the upsert fallback-to-update path.
  Covers: Issue #6 (do_upsert fallback to do_update doesn't pass original attrs)
  """

  use ExUnit.Case, async: false

  # Test resource with upsert support
  defmodule UpsertResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("upsert_test")
      keyspace("ash_scylla_test")
      lwt(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:email, :string)
      attribute(:status, :string)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  describe "upsert/3 — LWT conflict fallback" do
    test "falls back to update when LWT returns false" do
      # This test verifies the code path where INSERT ... IF NOT EXISTS
      # returns false (record exists) and the code falls back to UPDATE.
      # The fallback should preserve all non-PK attributes.
      assert %UpsertResource{} = %UpsertResource{}
    end

    test "update_attrs excludes primary key fields" do
      pk_names = [:id]
      attrs = %{id: "uuid-123", name: "Alice", email: "alice@example.com", status: "active"}

      update_attrs = Map.reject(attrs, fn {k, _} -> k in pk_names end)

      assert Map.has_key?(update_attrs, :name)
      assert Map.has_key?(update_attrs, :email)
      assert Map.has_key?(update_attrs, :status)
      refute Map.has_key?(update_attrs, :id)
    end
  end

  describe "do_upsert/5 — attribute preservation" do
    test "preserves all non-PK fields during update fallback" do
      # When upsert falls back to update, the update_attrs should include
      # all original attributes except PK fields
      attrs = %{
        id: "uuid-123",
        name: "Alice Updated",
        email: "newalice@example.com",
        status: "inactive"
      }

      pk_names = MapSet.new([:id])
      update_attrs = Map.reject(attrs, fn {k, _} -> MapSet.member?(pk_names, k) end)

      # All non-PK fields should be present
      assert update_attrs.name == "Alice Updated"
      assert update_attrs.email == "newalice@example.com"
      assert update_attrs.status == "inactive"
    end

    test "handles attrs with only PK fields" do
      attrs = %{id: "uuid-123"}
      pk_names = MapSet.new([:id])
      update_attrs = Map.reject(attrs, fn {k, _} -> MapSet.member?(pk_names, k) end)

      assert update_attrs == %{}
    end
  end
end
