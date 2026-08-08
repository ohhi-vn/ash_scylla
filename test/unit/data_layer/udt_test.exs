defmodule AshScylla.DataLayer.UdtTest do
  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Udt

  describe "create_type_cql/2" do
    test "generates CQL with atom type name" do
      cql = Udt.create_type_cql(:my_type, name: :text, age: :int)
      assert cql =~ "CREATE TYPE IF NOT EXISTS"
      assert cql =~ "my_type"
      assert cql =~ "name TEXT"
      assert cql =~ "age INT"
    end

    test "generates CQL with string type name" do
      cql = Udt.create_type_cql("my_type", name: :text)
      assert cql =~ "CREATE TYPE IF NOT EXISTS my_type"
      assert cql =~ "name TEXT"
    end

    test "handles multiple fields" do
      cql = Udt.create_type_cql("address", street: :text, city: :text, zip: :int)
      assert cql =~ "street TEXT"
      assert cql =~ "city TEXT"
      assert cql =~ "zip INT"
    end
  end

  describe "drop_type_cql/1" do
    test "generates CQL with atom" do
      assert Udt.drop_type_cql(:my_type) == "DROP TYPE IF EXISTS my_type"
    end

    test "generates CQL with string" do
      assert Udt.drop_type_cql("my_type") == "DROP TYPE IF EXISTS my_type"
    end
  end

  describe "alter_type_cql/3" do
    test "generates ALTER TYPE ADD with atom" do
      cql = Udt.alter_type_cql(:my_type, :add, email: :text)
      assert cql =~ "ALTER TYPE my_type"
      assert cql =~ "ADD email TEXT"
    end

    test "generates ALTER TYPE ADD with string" do
      cql = Udt.alter_type_cql("my_type", :add, email: :text)
      assert cql =~ "ALTER TYPE my_type"
      assert cql =~ "ADD email TEXT"
    end

    test "generates ALTER TYPE ADD for multiple fields" do
      cql = Udt.alter_type_cql("my_type", :add, email: :text, phone: :text)
      assert cql =~ "ADD email TEXT"
      assert cql =~ "ADD phone TEXT"
    end

    test "generates ALTER TYPE RENAME" do
      cql = Udt.alter_type_cql("my_type", :rename, new_name: :old_name)
      assert cql =~ "ALTER TYPE my_type"
      assert cql =~ "RENAME old_name TO new_name"
    end

    test "generates ALTER TYPE RENAME for multiple renames" do
      cql = Udt.alter_type_cql("my_type", :rename, a: :b, c: :d)
      assert cql =~ "RENAME b TO a"
      assert cql =~ "RENAME d TO c"
    end
  end

  describe "list_types_cql/0" do
    test "returns SELECT CQL" do
      assert Udt.list_types_cql() ==
               "SELECT type_name, field_names, field_types FROM system_schema.types"
    end
  end

  describe "type_exists_cql/1" do
    test "generates CQL with atom" do
      cql = Udt.type_exists_cql(:my_type)
      assert cql =~ "SELECT type_name FROM system_schema.types WHERE type_name = 'my_type'"
    end

    test "generates CQL with string" do
      cql = Udt.type_exists_cql("my_type")
      assert cql =~ "SELECT type_name FROM system_schema.types WHERE type_name = 'my_type'"
    end
  end

  describe "validate_fields/1" do
    test "accepts valid field list" do
      assert Udt.validate_fields(name: :text, age: :int) == :ok
    end

    test "rejects non-atom field name" do
      assert {:error, msg} = Udt.validate_fields([{"name", :text}])
      assert msg =~ "Field name must be an atom"
    end

    test "rejects non-atom field type" do
      assert {:error, msg} = Udt.validate_fields([{:name, "text"}])
      assert msg =~ "Field type must be an atom"
    end

    test "rejects invalid field type" do
      assert {:error, msg} = Udt.validate_fields([{:name, :invalid_type}])
      assert msg =~ "Invalid field type"
    end

    test "rejects non-list input" do
      assert {:error, msg} = Udt.validate_fields("not_a_list")
      assert msg =~ "Fields must be a list"
    end

    test "accepts empty field list" do
      assert Udt.validate_fields([]) == :ok
    end
  end

  describe "resource_udts/1" do
    test "returns empty list for resource without UDT attributes" do
      assert Udt.resource_udts(AshScylla.TestResource) == []
    end
  end

  describe "encode/2" do
    test "encodes a map to tuple" do
      result = Udt.encode(%{name: "Alice", age: 30}, AshScylla.TestResource)
      assert is_tuple(result)
      values = Tuple.to_list(result)
      assert values == [30, "Alice"]
    end

    test "encodes empty map to empty tuple" do
      result = Udt.encode(%{}, AshScylla.TestResource)
      assert result == {}
    end

    test "encodes single-key map" do
      result = Udt.encode(%{key: "value"}, AshScylla.TestResource)
      assert result == {"value"}
    end
  end

  describe "decode/2" do
    test "decodes a tuple to map with positional keys" do
      result = Udt.decode({:hello, 42}, AshScylla.TestResource)
      assert result == %{field_0: :hello, field_1: 42}
    end

    test "decodes empty data gracefully" do
      result = Udt.decode({}, AshScylla.TestResource)
      assert result == %{}
    end

    test "decodes single-element tuple" do
      result = Udt.decode({:single}, AshScylla.TestResource)
      assert result == %{field_0: :single}
    end

    test "decodes tuple with mixed types" do
      result = Udt.decode({"hello", 42, true}, AshScylla.TestResource)
      assert result == %{field_0: "hello", field_1: 42, field_2: true}
    end
  end

  describe "field_type_to_cql/1" do
    test "maps common field types to CQL" do
      assert Udt.field_type_to_cql(:text) == "TEXT"
      assert Udt.field_type_to_cql(:int) == "INT"
      assert Udt.field_type_to_cql(:uuid) == "UUID"
      assert Udt.field_type_to_cql(:boolean) == "BOOLEAN"
    end
  end
end
