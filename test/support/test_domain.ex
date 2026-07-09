defmodule AshScylla.TestDomain do
  @moduledoc "Test domain for AshScylla unit tests."
  use Ash.Domain,
    otp_app: :ash_scylla,
    validate_config_inclusion?: false

  resources do
    resource(AshScylla.TestResource)
    resource(AshScylla.TestResourceWithIndexes)
    resource(AshScylla.TestResourceCompositePK)
    resource(AshScylla.TestResourceNoKeyspace)
  end
end
