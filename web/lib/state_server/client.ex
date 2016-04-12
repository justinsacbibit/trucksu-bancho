defmodule Game.StateServer.Client do
  @moduledoc """
  The client API for the StateServer.
  """

  @name Game.StateServer

  @doc """
  After a user has been authenticated, add them into the global state. Joins the
  user into the default channels (#osu, #announce)
  """
  def add_user(server, user, token) do
    GenServer.cast(server, {:add_user, user, token})
  end

  @doc """
  Gets information about all connected users.
  """
  def users(server) do
    GenServer.call(server, :users)
  end
end
