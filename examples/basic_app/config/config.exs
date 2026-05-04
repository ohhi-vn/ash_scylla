import Config

config :basic_app, BasicApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "basic_app_dev",
  pool_size: 10,
  sync_connect: 5000,
  request_timeout: 60_000

config :logger, level: :info
