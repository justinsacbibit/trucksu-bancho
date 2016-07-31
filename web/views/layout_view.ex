defmodule Game.LayoutView do
  use Game.Web, :view

  def render("app.html", %{online: online}) do
    status = if online do
      "Online"
    else
      "Offline"
    end
    "trucksu!Bancho - #{status}"
  end
end

