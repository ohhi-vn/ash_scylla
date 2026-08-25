defmodule AshScylla.SupportResourceInspectTest do
  @moduledoc """
  Exercises the derived `Inspect` implementations for test support resources.

  Ash generates a `defimpl Inspect` per resource module; calling `inspect/1`
  on resource structs keeps those protocol implementations covered.
  """

  use ExUnit.Case, async: true

  describe "Inspect for resources without keyspace config" do
    test "renders the resource name and attributes" do
      record = %AshScylla.TestResourceNoKeyspace{name: "Ada", age: 36}
      rendered = inspect(record)

      assert rendered =~ "AshScylla.TestResourceNoKeyspace"
      assert rendered =~ "name: \"Ada\""
      assert rendered =~ "age: 36"
    end
  end

  describe "Inspect for resources without table config" do
    test "renders the resource name and attributes" do
      record = %AshScylla.TestResourceNoTable{name: "Grace"}
      rendered = inspect(record)

      assert rendered =~ "AshScylla.TestResourceNoTable"
      assert rendered =~ "name: \"Grace\""
    end

    test "renders an empty struct" do
      assert inspect(%AshScylla.TestResourceNoTable{}) =~ "AshScylla.TestResourceNoTable"
    end
  end
end
