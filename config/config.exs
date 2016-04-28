# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.
use Mix.Config

# Configures the endpoint
config :game, Game.Endpoint,
  url: [host: "localhost"],
  root: Path.dirname(__DIR__),
  secret_key_base: "S7YcvRYd0ZIs7a8bsMPYz2/PsoAGbgvGGh+kNA0TSLPb9TtpewYyr/rGIw0qZq36",
  render_errors: [accepts: ~w(json)],
  pubsub: [name: Game.PubSub,
           adapter: Phoenix.PubSub.PG2]

# Configures Elixir's Logger
config :logger, :console,
  # format: "$time $metadata[$level] $message\n",
  format: "$metadata[$level] $message\n",
  metadata: [],
  level: :warn

config :guardian, Guardian,
  issuer: "Trucksu",
  ttl: { 60, :days },
  verify_issuer: true,
  serializer: Trucksu.GuardianSerializer,
  secret_key: System.get_env("GUARDIAN_SECRET_KEY") || "e2z2aq3mz7GAiStke74ROQ13+nqNmNvXf6EuZNIsK8a8w00VOTLmEpGRBtdKhb5q"

config :game,
  server_cookie: "a",
  get_request_location: System.get_env("GET_REQUEST_LOCATION") || false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env}.exs"

# This line was automatically added by ansible-elixir-stack setup script
if System.get_env("SERVER") do
  config :phoenix, :serve_endpoints, true
end
