defmodule Game.Mixfile do
  use Mix.Project

  def project do
    [app: :game,
     version: "0.0.4",
     elixir: "~> 1.3",
     elixirc_paths: elixirc_paths(Mix.env),
     compilers: [:phoenix, :gettext] ++ Mix.compilers,
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [mod: {Game, []},
     applications: [:phoenix, :cowboy, :logger, :gettext, :timex, :httpoison,
                    :postgrex]]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "web", "test/support"]
  defp elixirc_paths(_),     do: ["lib", "web"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [{:phoenix, "~> 1.2.0"},
     {:gettext, "~> 0.9"},
     {:cowboy, "~> 1.0"},
     {:exredis, git: "https://github.com/artemeff/exredis.git"},
     {:timex, "2.1.4"},
     {:httpoison, ">= 0.0.0"},
     {:trucksu, path: "./trucksu-web"}]
  end
end
