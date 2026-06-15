defmodule AshScylla.SchemaFixtures do
  @moduledoc "Schema modules used in tests."
end

defmodule AshScylla.SchemaFixtures.SampleSchema do
  use AshScylla.Schema

  @impl AshScylla.Schema
  def change do
    [
      "CREATE TABLE IF NOT EXISTS sample (id UUID PRIMARY KEY, name TEXT)"
    ]
  end
end

defmodule AshScylla.SchemaFixtures.EmptySchema do
  use AshScylla.Schema
end
