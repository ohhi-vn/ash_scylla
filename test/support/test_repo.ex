defmodule AshScylla.TestRepo do
  @moduledoc """
  Test repo for AshScylla. Uses AshScylla.Repo with the :ash_scylla OTP app.
  Configuration is loaded from config/test.exs / config/config.exs.
  """
  use AshScylla.Repo, otp_app: :ash_scylla
end
