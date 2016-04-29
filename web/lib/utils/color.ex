defmodule Game.Utils.Color do
  def username(username) do
    color(username, IO.ANSI.blue)
  end

  def channel(channel) do
    color(channel, IO.ANSI.green)
  end

  def color(message, color) do
    color <> message <> IO.ANSI.reset
  end
end

