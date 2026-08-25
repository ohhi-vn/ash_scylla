defmodule AshScylla.MaterializedViewSchemaTest do
  @moduledoc "Covers the MaterializedView schema callback."

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.MaterializedView

  test "schema/0 documents the view configuration options" do
    schema = MaterializedView.schema()

    assert Keyword.get(schema, :primary_key) == [type: {:list, :atom}, required: true]
    assert Keyword.get(schema, :include_columns) == [type: {:list, :atom}]
    assert Keyword.get(schema, :clustering_order) == [type: :keyword_list]
  end
end
