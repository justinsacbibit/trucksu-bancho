defmodule Game.Utils do
  def color(message, color) do
    color <> message <> IO.ANSI.reset
  end
end

