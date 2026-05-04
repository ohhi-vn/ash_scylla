defmodule AshScylla do
  @moduledoc """
  AshScylla is a data layer for Ash Framework that uses ScyllaDB (via Exandra).

  ## Usage

  Configure your Ash resource to use AshScylla.DataLayer:

      defmodule MyApp.MyResource do
        use Ash.Resource,
          data_layer: AshScylla.DataLayer

        attributes do
          uuid_primary_key :id
          attribute :name, :string
          attribute :email, :string
        end
      end

  Configure your repo to use Exandra adapter:

      defmodule MyApp.Repo do
        use Ecto.Repo,
          otp_app: :my_app,
          adapter: Exandra
      end

  Then configure your resource to use the repo:

      # In your resource configuration
      use Ash.Resource,
        data_layer: AshScylla.DataLayer,
        repo: MyApp.Repo
  """

  @doc """
  Returns the version of AshScylla.
  """
  def version do
    {:ok, version} = :application.get_key(:ash_scylla, :vsn)
    to_string(version)
  end
end
