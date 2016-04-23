defmodule Game.StateServer.Client do
  @moduledoc """
  The client API for the StateServer.
  """
  require Logger
  alias Game.{Packet, Utils}

  @client :redis
  @default_channels ["#osu", "#announce"]
  @other_channels []

  @doc """
  Initializes Redis state if necessary. This should be called within the
  OTP application callback.
  """
  def initialize() do
    Logger.warn Utils.color("Initialized Redis state", IO.ANSI.green)
  end

  @doc """
  Clears Redis state, then reinitializes it.
  """
  def reset() do
    @client |> Exredis.query(["FLUSHALL"])

    Logger.warn "Cleared Redis state"

    initialize()
  end

  @doc """
  After a user has been authenticated, add them into the global state. Joins the
  user into the default channels (#osu, #announce).

  If the user is already in the state, resets their state.
  """
  def add_user(user, token) do
    remove_user_from_channels(user.id)

    query1 = [
      "HMSET",
      user_key(user.id),
      "username", user.username,
      "token", token,
      "action_id", 0,
      "action_text", "",
      "action_md5", "",
      "action_mods", 0,
      "game_mode", 0,
    ]

    query2 = ["HSET", "users", user.username, user.id]

    query3 = ["DEL", user_queue_key(user.id)]

    channel_queries = Enum.map @default_channels, fn default_channel ->
      ["SADD", channel_key(default_channel), user.id]
    end

    @client |> Exredis.query_pipe([query1, query2, query3] ++ channel_queries)
  end

  @doc """
  Removes a user from the state.

  Enqueues a logout packet to all other users, and removes the user from all channels.
  """
  def remove_user(user_id) do
    logout_packet = Packet.logout(user_id)

    username = @client |> Exredis.query(["HGET", user_key(user_id), "username"])

    @client |> Exredis.query_pipe([
      ["DEL", user_key(user_id)],
      ["HDEL", "users", username],
      ["DEL", user_queue_key(user_id)],
    ])

    enqueue_all(logout_packet)

    remove_user_from_channels(user_id)
  end

  @doc """
  Adds a user to the specified channel.
  """
  def join_channel(user_id, channel) do
    @client |> Exredis.query(["SADD", channel_key(channel), user_id])
  end

  @doc """
  Removes a user from the specified channel.
  """
  def part_channel(user_id, channel) do
    @client |> Exredis.query(["SREM", channel_key(channel), user_id])
  end

  #@doc """
  #Creates a new channel with the specified name. Should start with a #.
  #"""
  #def create_channel(server \\ @name, channel) do
  #end

  @doc """
  Sends a public message to a channel.
  """
  def send_public_message(channel, packet, from_user_id) do
    queries = @client
    |> Exredis.query(["SMEMBERS", channel_key(channel)])
    |> Enum.filter_map(fn user_id ->
      {user_id, _} = Integer.parse(user_id)
      user_id != from_user_id
    end, fn user_id ->
      ["RPUSH", user_queue_key(user_id), packet]
    end)

    @client |> Exredis.query_pipe(queries)
  end

  @doc """
  Gets information about all connected users.
  """
  def users() do
    raise "StateServer.Client.users not implemented yet"
  end

  @doc """
  Gets the user ids of all connected users.
  """
  def user_ids() do
    user_keys = @client |> Exredis.query(["KEYS", user_key("*")])

    Enum.map user_keys, fn "user:" <> user_id ->
      {user_id, _} = Integer.parse(user_id)
      user_id
    end
  end

  @doc """
  Enqueues a packet to be sent to a user.
  """
  def enqueue(user_id, packet) do
    @client |> Exredis.query(["RPUSH", user_queue_key(user_id), packet])
  end

  @doc """
  Enqueues a packet to be sent to a user, identified by their username.
  """
  def enqueue_for_username(username, packet) do
    user_id = @client |> Exredis.query(["HGET", "users", username])

    enqueue(user_id, packet)
  end

  @doc """
  Enqueues a packet to be sent to all users.
  """
  def enqueue_all(packet) do
    queues = @client |> Exredis.query(["KEYS", user_queue_key("*")])

    queries = Enum.map queues, fn queue ->
      ["RPUSH", queue, packet]
    end

    @client |> Exredis.query_pipe(queries)
  end

  @doc """
  Dequeues all packets to be sent to a user.

  Returns the packet queue.
  """
  def dequeue(user_id) do
    # I pray that the LTRIM returns OK
    [_, _, _, [packet_queue, "OK"]] = @client |> Exredis.query_pipe([
      ["MULTI"],
      ["LRANGE", user_queue_key(user_id), "0", "-1"],
      ["LTRIM", user_queue_key(user_id), "1", "0"],
      ["EXEC"],
    ])

    packet_queue
  end

  @doc """
  Gets information about all channels.
  """
  def channels() do
    raise "StateServer.Client.channels not implemented yet"
  end

  @doc """
  Sends a message to a channel.
  """
  def send_message() do
    raise "StateServer.Client.send_message not implemented yet"
  end

  @doc """
  Changes the current action for a user.
  """
  def change_action(user_id, action) do
    query = [
      "HMSET",
      user_key(user_id),
      "action_id", action[:action_id],
      "action_text", action[:action_text],
      "action_md5", action[:action_md5],
      "action_mods", action[:action_mods],
      "game_mode", action[:game_mode],
    ]

    @client |> Exredis.query(query)
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
  def action(user_id) do
    list = @client |> Exredis.query([
      "HMGET",
      "user:#{user_id}",
      "action_id",
      "action_md5",
      "action_text",
      "action_mods",
      "game_mode",
    ])
    [action_id, action_text, action_md5, action_mods, game_mode] = list

    {action_id, _} = Integer.parse(action_id)
    {action_mods, _} = Integer.parse(action_mods)
    {game_mode, _} = Integer.parse(game_mode)

    [
      action_id: action_id,
      action_text: action_text,
      action_md5: action_md5,
      action_mods: action_mods,
      game_mode: game_mode,
    ]
  end

  ## Helper functions

  defp remove_user_from_channels(user_id) do
    channels = @client |> Exredis.query(["KEYS", channel_key("*")])

    Enum.each channels, fn channel ->
      @client |> Exredis.query(["SREM", channel, user_id])
    end
  end

  # Constructs the Redis key for a user hash
  defp user_key(user_id) do
    "user:#{user_id}"
  end

  # Constructs the Redis key for a user packet queue
  defp user_queue_key(user_id) do
    "user.packet_queue:#{user_id}"
  end

  # Constructs the Redis key for a channel
  defp channel_key(channel) do
    "channel:#{channel}"
  end
end
