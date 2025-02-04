defmodule Game do
  use Application

  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      # Start the endpoint when the application starts
      supervisor(Game.Endpoint, []),
      # Here you could define other workers and supervisors as children
      supervisor(Trucksu.Repo, []),
      # worker(Game.Worker, [arg1, arg2, arg3]),
      worker(Game.Redis, [:redis]),
      worker(Game.UserTimeout, []),
      worker(Game.MatchJanitor, []),
      worker(Game.TruckLord, []),
    ]

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Game.Supervisor]
    ret = Supervisor.start_link(children, opts)

    Game.StateServer.Client.initialize

    ret
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    Game.Endpoint.config_change(changed, removed)
    :ok
  end
end
