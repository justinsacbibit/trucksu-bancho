defmodule Game.GameView do
  use Game.Web, :view

  def render("response.raw", %{data: data}), do: data
end

