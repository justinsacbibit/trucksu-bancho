use Mix.Config

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we use it
# with brunch.io to recompile .js and .css sources.
config :game, Game.Endpoint,
  http: [port: 4002],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: []

# Do not include metadata nor timestamps in development logs
# config :logger, :console, format: "[$level] $message\n"

config :game,
  server_cookie: "a",
  trucksu_api_url: "http://localhost:4000/api",
  website_url: System.get_env("WEBSITE_URL") || "http://localhost:4001",
  get_request_location: true

# Set a higher stacktrace during development.
# Do not configure such in production as keeping
# and calculating stacktraces is usually expensive.
config :phoenix, :stacktrace_depth, 20

config :trucksu, Trucksu.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: "postgres_db",
  password: "postgres_db",
  database: "trucksu_dev",
  hostname: "localhost",
  pool_size: 10

config :exredis,
  host: "127.0.0.1",
  port: 6379,
  password: "",
  db: 0,
  reconnect: :no_reconnect,
  max_queue: :infinity

