defmodule BasicApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      BasicApp.Repo
    ]

    opts = [strategy: :one_for_one, name: BasicApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
