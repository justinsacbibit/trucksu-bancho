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
  def add_user(user, token) do
    add_user(@name, user, token)
  end

  @doc """
  Gets information about all connected users.
  """
  def users(server) do
    GenServer.call(server, :users)
  end
  def users() do
    users(@name)
  end

  @doc """
  Enqueues a packet to be sent to a user.
  """
  def enqueue(server, user_id, packet) do
    GenServer.cast(server, {:enqueue, user_id, packet})
  end
  def enqueue(user_id, packet) do
    enqueue(@name, user_id, packet)
  end

  @doc """
  Dequeues all packets to be sent to a user.

  Returns the packet queue.
  """
  def dequeue(server, user_id) do
    GenServer.call(server, {:dequeue, user_id})
  end
  def dequeue(user_id) do
    dequeue(@name, user_id)
  end

  @doc """
  Gets information about all channels.
  """
  def channels(server) do
    GenServer.call(server, :channels)
  end
  def channels() do
    channels(@name)
  end
end
