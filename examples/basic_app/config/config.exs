import Config

config :basic_app, BasicApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "basic_app_dev",
  connect_timeout: 5_000

config :logger, level: :info
