defmodule Game.PageView do
  use Game.Web, :view

  def render("response.raw", _assigns) do
    "<!DOCTYPE html><body>trucksu!Bancho</body>"
  end
end

