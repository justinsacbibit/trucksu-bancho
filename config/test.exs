use Mix.Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :game, Game.Endpoint,
  http: [port: 4001],
  server: false

# Print only warnings and errors during test
config :logger, level: :warn

config :trucksu, Trucksu.Repo,
adapter: Ecto.Adapters.Postgres,
username: "postgres_db",
password: "postgres_db",
database: "trucksu_test",
hostname: "localhost",
pool_size: 10
