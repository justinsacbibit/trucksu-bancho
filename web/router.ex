defmodule Game.Router do
  use Game.Web, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", Game do
    pipe_through :api

    scope "/v1" do
      scope "/users" do
        get "/", UserController, :index
        get "/:id", UserController, :show
      end
    end
  end

  scope "/", Game do
    get "/", PageController, :index
    post "/", GameController, :index
  end

  scope "/event", Game do
    pipe_through :api

    post "/", EventController, :index
  end
end
