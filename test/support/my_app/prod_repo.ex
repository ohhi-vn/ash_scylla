defmodule MyApp.ProdRepo do
  @moduledoc """
  AshScylla Repo for my_app.

  Manages the Xandra connection to ScyllaDB.
  """

  use AshScylla.Repo,
    otp_app: :my_app
end
