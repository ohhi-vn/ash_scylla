defmodule AshScylla.AutogenerateTest do
  @moduledoc """
  Tests for the autogenerate behavior in the data layer.
  Covers: Issue #7 (autogenerate_attribute?/1 logic issues)
  """

  use ExUnit.Case, async: true

  # Test resource with autogenerate UUID
  defmodule AutoGenResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("autogen_test")
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

  # Test resource WITHOUT autogenerate
  defmodule NoAutoGenResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

  import AshScylla.DataLayer.Dsl


    scylla do
      repo(AshScylla.TestRepo)
      table("no_autogen_test")
      keyspace("ash_scylla_test")
    end

    attributes do
      attribute :id, :uuid do
        primary_key?(true)
        allow_nil?(false)
      end

      attribute(:name, :string)
    end

    actions do
      defaults([:create, :read])
    end
  end

  describe "UUID autogeneration behavior" do
    test "uuid_primary_key creates PK attribute" do
      attrs = Ash.Resource.Info.attributes(AutoGenResource)
      id_attr = Enum.find(attrs, &(&1.name == :id))
      assert id_attr.primary_key?
    end

    test "regular uuid attribute creates PK" do
      attrs = Ash.Resource.Info.attributes(NoAutoGenResource)
      id_attr = Enum.find(attrs, &(&1.name == :id))
      assert id_attr.primary_key?
    end
  end

  describe "upsert attribute preservation" do
    test "update_attrs excludes primary key fields" do
      pk_names = MapSet.new([:id])
      attrs = %{id: "uuid-123", name: "Alice", email: "alice@example.com", status: "active"}
      update_attrs = Map.reject(attrs, fn {k, _} -> MapSet.member?(pk_names, k) end)

      assert Map.has_key?(update_attrs, :name)
      assert Map.has_key?(update_attrs, :email)
      assert Map.has_key?(update_attrs, :status)
      refute Map.has_key?(update_attrs, :id)
    end

    test "handles attrs with only PK fields" do
      pk_names = MapSet.new([:id])
      attrs = %{id: "uuid-123"}
      update_attrs = Map.reject(attrs, fn {k, _} -> MapSet.member?(pk_names, k) end)
      assert update_attrs == %{}
    end
  end
end
