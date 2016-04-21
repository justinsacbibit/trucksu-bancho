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
  Removes a user from the state.

  Enqueues a logout packet to all other users, and removes the user from all channels.
  """
  def remove_user(server, user_id) do
    GenServer.cast(server, {:remove_user, user_id})
  end
  def remove_user(user_id) do
    remove_user(@name, user_id)
  end

  @doc """
  Adds a user to the specified channel.
  """
  def join_channel(server \\ @name, user_id, channel) do
    GenServer.cast(server, {:join_channel, user_id, channel})
  end

  @doc """
  Removes a user from the specified channel.
  """
  def part_channel(server \\ @name, user_id, channel) do
    GenServer.cast(server, {:part_channel, user_id, channel})
  end

  @doc """
  Creates a new channel with the specified name. Should start with a #.
  """
  def create_channel(server \\ @name, channel) do
    GenServer.cast(server, {:create_channel, channel})
  end

  @doc """
  Sends a public message to a channel.
  """
  def send_public_message(server \\ @name, channel, packet, from_user_id) do
    GenServer.cast(server, {:send_public_message, channel, packet, from_user_id})
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
  Enqueues a packet to be sent to a user, identified by their username.
  """
  def enqueue_for_username(server \\ @name, username, packet) do
    GenServer.cast(server, {:enqueue_for_username, username, packet})
  end

  @doc """
  Enqueues a packet to be sent to all users.
  """
  def enqueue_all(server, packet) do
    GenServer.cast(server, {:enqueue_all, packet})
  end
  def enqueue_all(packet) do
    enqueue_all(@name, packet)
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

  @doc """
  Sends a message to a channel.
  """
  def send_message()

  @doc """
  Changes the current action for a user.
  """
  def change_action(server, user_id, action) do
    GenServer.cast(server, {:change_action, user_id, action})
  end
  def change_action(user_id, action) do
    change_action(@name, user_id, action)
  end

  @doc """
  Returns the current action for a user.

  The return format is a keyword list with the following keys:
    - action_id
    - action_text
    - action_md5
    - action_mods
    - game_mode
  """
  def action(server, user_id) do
    GenServer.call(server, {:action, user_id})
  end
  def action(user_id) do
    action(@name, user_id)
  end

  @doc """
  Resets the server state.
  """
  def reset(server \\ @name) do
    GenServer.cast(server, :reset)
  end
end
