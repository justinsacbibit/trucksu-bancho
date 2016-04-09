defmodule Game.Router do
  use Game.Web, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", Game do
    pipe_through :api
  end

  scope "/", Game do
    get "/", PageController, :index
    post "/", GameController, :index
  end
end
