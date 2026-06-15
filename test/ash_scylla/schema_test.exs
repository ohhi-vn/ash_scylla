defmodule AshScylla.SchemaTest do
  use ExUnit.Case, async: true

  alias AshScylla.SchemaFixtures.{SampleSchema, EmptySchema}

  describe "behaviour" do
    test "defines change/0 callback" do
      assert function_exported?(SampleSchema, :change, 0)
    end

    test "schema module returns list of CQL strings" do
      statements = SampleSchema.change()
      assert is_list(statements)
      assert Enum.all?(statements, &is_binary/1)
    end

    test "schema module returns expected CQL" do
      [create_table] = SampleSchema.change()
      assert create_table =~ "CREATE TABLE IF NOT EXISTS"
      assert create_table =~ "id UUID PRIMARY KEY"
    end
  end

  describe "default change/0" do
    test "returns empty list when not implemented" do
      assert EmptySchema.change() == []
    end
  end

  test "behaviour info lists change/0" do
    callbacks = AshScylla.Schema.behaviour_info(:callbacks)
    assert {:change, 0} in callbacks
  end
end
