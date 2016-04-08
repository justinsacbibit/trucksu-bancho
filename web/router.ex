defmodule Game.Router do
  use Game.Web, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", Game do
    pipe_through :api
  end

  # The following calls go to c.ppy.sh or c1.ppy.sh
  post "/", Game.GameController, :index
end
