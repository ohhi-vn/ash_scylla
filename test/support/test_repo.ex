defmodule AshScylla.TestRepo do
  @moduledoc "Test repository for integration tests with ScyllaDB."
  use Ecto.Repo, adapter: Exandra, otp_app: :ash_scylla

  @impl Ecto.Repo
  def init(_type, config) do
    {:ok, Keyword.drop(config, [:label])}
  end
end
