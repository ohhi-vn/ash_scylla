defmodule MyApp.CustomRepo do
  @moduledoc """
  AshScylla Repo for ash_scylla.

  Manages the Xandra connection to ScyllaDB.
  """

  use AshScylla.Repo,
    otp_app: :ash_scylla
end
