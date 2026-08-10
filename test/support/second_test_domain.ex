defmodule AshScylla.SecondTestDomain do
  @moduledoc """
  Second test domain for AshScylla multi-domain tests.

  Hosts resources that use a different keyspace than `AshScylla.TestDomain`
  (both a resource-level keyspace override and a repo-level keyspace) so the
  data layer can be verified when an application registers multiple domains.
  """
  use Ash.Domain,
    otp_app: :ash_scylla,
    validate_config_inclusion?: false

  resources do
    resource(AshScylla.SecondTestDomain.Resource)
    resource(AshScylla.SecondTestDomain.RepoBackedResource)
  end
end
