defmodule MyApp.Repo.Migrations.CreateUserIndexes do
  use Ecto.Migration

  def change do
    # Create secondary indexes for MyApp.User resource
    # This assumes the table already exists from a previous migration

    AshScylla.Migration.create_secondary_indexes_cql(MyApp.User)
    |> Enum.each(&execute/1)
  end
end
