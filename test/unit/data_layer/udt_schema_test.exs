defmodule AshScylla.DataLayer.UdtSchemaTest do
  @moduledoc """
  Coverage for `AshScylla.DataLayer.Udt` encode/decode schema matching and
  `resource_udts/1` extraction, using lightweight fake attribute maps.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Udt

  defp udt_resource(attrs) do
    entities = Enum.map(attrs, fn attr -> Map.merge(%{type: :udt}, attr) end)
    %{[:attributes] => %{entities: entities}}
  end

  describe "resource_udts/1" do
    test "extracts UDT attributes with explicit type names and fields" do
      resource =
        udt_resource([
          %{
            name: :address,
            constraints: [type_name: "address_type", fields: [street: :text, zip: :int]]
          }
        ])

      assert [%{name: :address, type_name: "address_type", fields: fields}] =
               Udt.resource_udts(resource)

      assert fields == [street: :text, zip: :int]
    end

    test "defaults the type name to the uppercased attribute name" do
      resource = udt_resource([%{name: :location, constraints: []}])

      assert [%{type_name: "LOCATION", fields: []}] = Udt.resource_udts(resource)
    end

    test "accepts atom and binary type names" do
      resource =
        udt_resource([
          %{name: :a, constraints: [type_name: :atom_name]},
          %{name: :b, constraints: [type_name: "bin_name"]}
        ])

      assert [%{type_name: "atom_name"}, %{type_name: "bin_name"}] = Udt.resource_udts(resource)
    end

    test "ignores malformed field lists" do
      resource = udt_resource([%{name: :weird, constraints: [fields: :not_a_list]}])

      assert [%{fields: []}] = Udt.resource_udts(resource)
    end

    test "skips non-UDT attributes" do
      resource = %{
        [:attributes] => %{
          entities: [
            %{name: :plain, type: :string, constraints: []},
            %{name: :u, type: :udt, constraints: [fields: [x: :int]]}
          ]
        }
      }

      assert [%{name: :u}] = Udt.resource_udts(resource)
    end

    test "handles resources without attributes" do
      assert Udt.resource_udts(%{[:attributes] => %{entities: []}}) == []
    end
  end

  describe "encode/2 with a matching UDT schema" do
    test "orders values by the declared field list" do
      resource =
        udt_resource([%{name: :address, constraints: [fields: [zip: :int, street: :text]]}])

      assert Udt.encode(%{street: "Main St", zip: 1234}, resource) == {1234, "Main St"}
    end

    test "keeps declared order and preserves explicit nil values" do
      resource = udt_resource([%{name: :point, constraints: [fields: [y: :int, x: :int]]}])

      assert Udt.encode(%{x: 7, y: nil}, resource) == {nil, 7}
    end
  end

  describe "decode/2 with a matching UDT schema" do
    test "maps tuple positions to schema field names" do
      resource =
        udt_resource([%{name: :address, constraints: [fields: [street: :text, zip: :int]]}])

      assert Udt.decode({"Main St", 99}, resource) == %{street: "Main St", zip: 99}
    end

    test "falls back to positional keys when no schema matches" do
      resource = udt_resource([%{name: :pair, constraints: [fields: [a: :text, b: :text]]}])

      assert Udt.decode({1, 2, 3}, resource) == %{field_0: 1, field_1: 2, field_2: 3}
    end
  end
end
