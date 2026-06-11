defmodule Mix.Tasks.AshScylla.Gen do
  @moduledoc """
  Generates an Ash Resource template backed by AshScylla.

  ## Usage

      mix ash_scylla.gen MyResource user_id:uuid, name:string, age:int

  The task writes a resource file under `lib/<app>/resources/<resource>.ex`.
  It creates a starter template that you can customize with primary keys,
  actions, repo, and ScyllaDB-specific options.

  ## Examples

      mix ash_scylla.gen User user_id:uuid, name:string, age:int
  """

  @shortdoc "Generates an AshScylla resource template"

  @requirements ["app.start"]

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    case AshScylla.ResourceGenerator.parse_args(args) do
      {:ok, resource_name, attributes} ->
        AshScylla.ResourceGenerator.write_resource(resource_name, attributes)

      {:error, message} ->
        Mix.raise(message)
    end
  end
end
