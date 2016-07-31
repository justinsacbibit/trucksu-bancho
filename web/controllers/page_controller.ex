defmodule Game.PageController do
  use Game.Web, :controller
  alias Trucksu.{Repo, User}

  def index(conn, _params) do
    user = Repo.get User, 1
    online = not is_nil(user)
    render conn, "index.html", online: online
  end
end

