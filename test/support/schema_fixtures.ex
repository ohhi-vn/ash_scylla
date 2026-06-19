defmodule AshScylla.SchemaFixtures do
  @moduledoc """
  Shared schema fixtures for migration and schema tests.
  """

  defmodule SampleSchema do
    @moduledoc "A sample schema that implements the AshScylla.Schema behaviour."
    @behaviour AshScylla.Schema

    @impl true
    def change do
      [
        "CREATE TABLE IF NOT EXISTS sample_table (id UUID PRIMARY KEY, name TEXT)"
      ]
    end
  end

  defmodule EmptySchema do
    @moduledoc "A schema that returns an empty change list (default behaviour)."
    @behaviour AshScylla.Schema

    @impl true
    def change do
      []
    end
  end
end
