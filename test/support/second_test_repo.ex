defmodule AshScylla.SecondTestRepo do
  @moduledoc """
  Second test repo for AshScylla multi-domain tests.

  Configured with its own keyspace in `config/test.exs`, so resources that
  point at this repo resolve a different keyspace than resources using
  `AshScylla.TestRepo` — even when they belong to different domains.
  """
  use AshScylla.Repo, otp_app: :ash_scylla
end
