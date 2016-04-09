defmodule Game.LayoutView do
  use Game.Web, :view

  def render("app.html", %{user: user}) do
    "trucksu!Bancho - #{user.username}"
  end
end

