defmodule Game.StateServer.Client do
  @moduledoc """
  The client API for the StateServer.
  """
  require Logger
  use Timex
  alias Game.{Packet, Utils}
  alias Trucksu.{Repo, User}

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
  Updates the time of the user's last request to now. Used to check if a client
  has been disconnected for an extended period of time.
  """
  def update_last_request_time(user_id) do
    {time0, time1, time2} = Time.now
    @client |> Exredis.query([
      "HMSET",
      user_key(user_id),
      "last_request_time0", time0,
      "last_request_time1", time1,
      "last_request_time2", time2,
    ])
  end

  @doc """
  """
  def retrieve_last_request_time(user_id) do
    [time0, time1, time2] = @client |> Exredis.query([
      "HMGET",
      user_key(user_id),
      "last_request_time0",
      "last_request_time1",
      "last_request_time2",
    ])

    {time0, _} = Integer.parse(time0)
    {time1, _} = Integer.parse(time1)
    {time2, _} = Integer.parse(time2)

    {time0, time1, time2}
  end

  @doc """
  After a user has been authenticated, add them into the global state. Joins the
  user into the default channels (#osu, #announce).

  If the user is already in the state, resets their state.
  """
  def add_user(user, token, {[lat, lon], country_id} \\ {[0.0, 0.0], 0}) do
    remove_user_from_channels(user.id)

    {time0, time1, time2} = Time.now

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
      "last_request_time0", time0,
      "last_request_time1", time1,
      "last_request_time2", time2,
      "lat", "#{lat}",
      "lon", "#{lon}",
      "country_id", "#{country_id}",
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

    stop_spectating(user_id)

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
  Sends a message to the appropriate #spectator channel.
  """
  def send_spectator_message(packet, from_spectator_id) do
    spectatee_id = @client |> Exredis.query(["HGET", user_key(from_spectator_id), "spectating"])

    spectators = if spectatee_id == :undefined do
      # The sender might be the host
      @client |> Exredis.query(["SMEMBERS", user_spectators_key(from_spectator_id)])
    else
      spectators = @client |> Exredis.query(["SMEMBERS", user_spectators_key(spectatee_id)])
      [spectatee_id | spectators]
    end

    queries = Enum.filter_map(spectators, fn user_id ->
      {user_id, _} = Integer.parse(user_id)
      user_id != from_spectator_id
    end, fn user_id ->
      ["RPUSH", user_queue_key(user_id), packet]
    end)

    @client |> Exredis.query_pipe(queries)
  end

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
  Gets the username of the user with the given user id.
  """
  def username(user_id) do
    @client |> Exredis.query(["HGET", user_key(user_id), "username"])
  end

  @doc """
  Checks if the user with the given id is connected.
  """
  def is_connected(user_id) do
    @client |> Exredis.query(["EXISTS", user_key(user_id)])
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
    user = Repo.get_by User, username: username
    enqueue(user.id, packet)
  end

  @doc """
  Enqueues a packet to be sent to all users.
  """
  def enqueue_all(packet) do
    user_keys = @client |> Exredis.query(["KEYS", user_key("*")])

    queries = Enum.map user_keys, fn "user:" <> user_id ->
      ["RPUSH", user_queue_key(user_id), packet]
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
  def change_action(user, action) do
    query = [
      "HMSET",
      user_key(user.id),
      "action_id", action[:action_id],
      "action_text", action[:action_text],
      "action_md5", action[:action_md5],
      "action_mods", action[:action_mods],
      "game_mode", action[:game_mode],
    ]

    @client |> Exredis.query(query)

    user_panel_packet = Packet.user_panel(user, action)
    user_stats_packet = Packet.user_stats(user, action)
    enqueue_all(user_panel_packet)
    enqueue_all(user_stats_packet)
  end

  @doc """
  Begin spectating a user.
  """
  def spectate(spectator_id, spectatee_id) do
    current_spectatee_id = @client |> Exredis.query(["HGET", "user:#{spectator_id}", "spectating"])

    # If the spectator is watching someone, remove them from that someone's list of spectators
    if current_spectatee_id != :undefined do
      @client |> Exredis.query(["SREM", "user.spectators:#{current_spectatee_id}", spectator_id])

      enqueue(current_spectatee_id, Packet.remove_spectator(spectator_id))
    end

    if is_connected(spectatee_id) do

      # TODO: Pipeline Redis queries

      @client |> Exredis.query_pipe([
        # Set who the spectator is spectating
        ["HSET", "user:#{spectator_id}", "spectating", spectatee_id],
        # Add the spectator to the host's list of spectators
        ["SADD", "user.spectators:#{spectatee_id}", spectator_id],
      ])

      # Send spectator join packet to host
      enqueue(spectatee_id, Packet.add_spectator(spectator_id))

      # Join #spectator channel
      enqueue(spectator_id, Packet.channel_join_success("#spectator"))

      num_spectators = @client |> Exredis.query(["SCARD", "user.spectators:#{spectatee_id}"])
      {num_spectators, _} = Integer.parse(num_spectators)

      if num_spectators == 1 do
        # First spectator, send #spectator join to host too
        enqueue(spectatee_id, Packet.channel_join_success("#spectator"))
      end
    end
  end

  @doc """
  Spectate frame event.
  """
  def spectate_frames(host_id, data) do
    spectator_ids = @client |> Exredis.query(["SMEMBERS", "user.spectators:#{host_id}"])

    Enum.map(spectator_ids, fn spectator_id ->
      {spectator_id, _} = Integer.parse(spectator_id)
      spectator_id
    end)
    |> Enum.each(fn spectator_id ->
      if spectator_id == host_id do
        Logger.error "Yes, spectator_id can equal host_id"
      else
        # TODO: Pipeline Redis queries
        enqueue(spectator_id, Packet.spectator_frames(data))
      end
    end)
  end

  @doc """
  Stop spectating.
  """
  def stop_spectating(spectator_id) do
    current_spectatee_id = @client |> Exredis.query(["HGET", "user:#{spectator_id}", "spectating"])

    # If the spectator is watching someone, remove them from that someone's list of spectators
    if current_spectatee_id != :undefined do
      @client |> Exredis.query_pipe([
        # Remove ourselves from the set of spectators
        ["SREM", "user.spectators:#{current_spectatee_id}", spectator_id],
        # Set who we're spectating to nil
        ["HDEL", "user:#{spectator_id}", "spectating"],
      ])

      enqueue(current_spectatee_id, Packet.remove_spectator(spectator_id))
    else
      Logger.error "Undefined current_spectatee_id in StateServer.Client.stop_spectating/1"
      Logger.error "spectator_id=#{spectator_id}"
    end
  end

  @doc """
  Can't spectate.
  """
  def cant_spectate(spectator_id) do
    current_spectatee_id = @client |> Exredis.query(["HGET", "user:#{spectator_id}", "spectating"])
    # If the spectator is watching someone
    if current_spectatee_id != :undefined do
      enqueue(current_spectatee_id, Packet.no_song_spectator(spectator_id))
    end
  end

  @doc """
  Returns all location data for a connected user.
  """
  def user_location(user_id) do
    list = @client |> Exredis.query([
      "HMGET",
      "user:#{user_id}",
      "lat",
      "lon",
      "country_id",
    ])
    [lat, lon, country_id] = list
    case lat do
      :undefined ->
        {[0.0, 0.0], 0}
      _ ->
        {lat, _} = Float.parse(lat)
        {lon, _} = Float.parse(lon)
        {country_id, _} = Integer.parse(country_id)
        {[lat, lon], country_id}
    end
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
      "action_text",
      "action_md5",
      "action_mods",
      "game_mode",
    ])
    [action_id, action_text, action_md5, action_mods, game_mode] = list

    case action_id do
      :undefined ->
        Logger.warn "Attempted to get action for #{user_id}, who appears to be offline"
        nil
      _ ->
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

  defp user_spectators_key(user_id) do
    "user.spectators:#{user_id}"
  end

  # Constructs the Redis key for a channel
  defp channel_key(channel) do
    "channel:#{channel}"
  end
end
