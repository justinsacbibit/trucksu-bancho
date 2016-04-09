defmodule Game.PageController do
  use Game.Web, :controller
  alias Trucksu.{Repo, User}

  def index(conn, _params) do
    user = Repo.get! User, 1
    render conn, "index.html", user: user
  end
end

