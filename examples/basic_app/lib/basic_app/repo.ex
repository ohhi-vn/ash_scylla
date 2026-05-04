defmodule BasicApp.Repo do
  use AshScylla.Repo,
    otp_app: :basic_app
end
