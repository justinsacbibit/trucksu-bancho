defmodule Game.StateServer.Client do
  @moduledoc """
  The client API for the StateServer.
  """
  require Logger
  use Timex
  use Bitwise
  alias Game.Packet
  alias Game.Utils.Color
  alias Trucksu.{Repo, User}

  @client :redis
  @default_channels ["#osu", "#announce"]
  @other_channels ["#lobby"] # this does nothing right now
  @lobby_key "mp_lobby"

  # Determines the amount of time to ignore logout requests after logging in.
  @recently_logged_in_threshold 10 # seconds

  ## match scoring types
  @match_scoring_type_score 0
  @match_scoring_type_accuracy 1
  @match_scoring_type_combo 2

  ## match team types
  @match_team_type_head_to_head 0
  @match_team_type_tag_coop 1
  @match_team_type_team_vs 2
  @match_team_type_tag_team_vs 3

  ## match mod modes
  @match_mod_mode_normal 0
  @match_mod_mode_free_mod 1

  ## slot statuses
  @slot_status_free 1
  @slot_status_locked 2
  @slot_status_not_ready 4
  @slot_status_ready 8
  @slot_status_no_map 16
  @slot_status_playing 32
  @slot_status_occupied 124
  @slot_status_playing_quit 128

  def match_mod_mode_free_mod(), do: @match_mod_mode_free_mod
  def slot_status_free(), do: @slot_status_free
  def slot_status_locked(), do: @slot_status_locked

  @doc """
  Initializes Redis state if necessary. This should be called within the
  OTP application callback.
  """
  def initialize() do
    next_match_id() # Initialize next_match_id to 0 if necessary
    Logger.warn Color.color("Initialized Redis state", IO.ANSI.green)
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
  def add_user(user, token, [lat, lon] \\ [0.0, 0.0], country_id \\ 0) do
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
      "match_id", "-1",
      "slot_id", "-1",
    ]

    query2 = ["HSET", "users", user.username, user.id]

    # Clear the user's current packet queue, if present
    query3 = ["DEL", user_queue_key(user.id)]

    # Used to keep track of whether the user recently logged in, so that we
    # can ignore logout packets that occur too soon
    query4 = ["SET", user_login_key(user.id), "1", "EX", "#{@recently_logged_in_threshold}"]

    channel_queries = Enum.map @default_channels, fn default_channel ->
      ["SADD", channel_key(default_channel), user.id]
    end

    @client |> Exredis.query_pipe([query1, query2, query3, query4] ++ channel_queries)

    # TODO: Lots of redundant queries here
    user_panel_packet = Packet.user_panel(user)
    user_stats_packet = Packet.user_stats(user)
    enqueue_all(user_panel_packet)
    enqueue_all(user_stats_packet)
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
      part_lobby_query(user_id),
    ])

    part_match(user_id)

    stop_spectating(user_id, false)

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
  Sends a message to the appropriate #multiplayer channel.
  """
  def send_multiplayer_message(packet, user) do
    match_id = @client |> Exredis.query(["HGET", user_key(user.id), "match_id"])

    case match_id do
      :undefined ->
        Logger.error "#{Color.username(user.username)} attempted to send a message to #multiplayer, but appears to be offline"
      "-1" ->
        Logger.error "#{Color.username(user.username)} attempted to send a message to #multiplayer, but appears to not be in a match"
      _ ->

        match_users = @client |> Exredis.query(["SMEMBERS", match_users_key(match_id)])

        queries = Enum.filter_map(match_users, fn(match_user_id) ->
          {match_user_id, _} = Integer.parse(match_user_id)
          match_user_id != user.id
        end, fn(match_user_id) ->
          ["RPUSH", user_queue_key(match_user_id), packet]
        end)

        @client |> Exredis.query_pipe(queries)
    end
  end

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

  Args:
    - `force`::bool (optional): Should be set to false if the caller does not
        know if the user is actually spectating someone. Useful for when a
        user is logging out.
  """
  def stop_spectating(spectator_id, force \\ true) do
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
      if force do
        Logger.error "Undefined current_spectatee_id in StateServer.Client.stop_spectating/1"
        Logger.error "spectator_id=#{spectator_id}"
      end
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

  @doc """
  Determines if a user has logged in within the past @recently_logged_in_threshold seconds.
  """
  def recently_logged_in?(user_id) do
    exists = @client |> Exredis.query(["EXISTS", user_login_key(user_id)])

    case exists do
      "1" ->
        true
      "0" ->
        false
      _ ->
        Logger.error "recently_logged_in? got unknown exists value: #{exists}"
        false
    end
  end

  @doc """
  Adds a player into the multiplayer lobby.
  """
  def join_lobby(user_id) do

    # TODO: Pipelining

    @client |> Exredis.query(["SADD", @lobby_key, user_id])

    # TODO: Send a createMatch packet for each match in the lobby

    packets = [<<>>]
    packet = Enum.reduce(packets, <<>>, &<>/2)
    enqueue(user_id, packet)
  end

  @doc """
  Removes a player from the multiplayer lobby.
  """
  def part_lobby(user_id) do
    @client |> Exredis.query(part_lobby_query(user_id))
  end

  # TODO: Extract into query builder
  defp part_lobby_query(user_id), do: ["SREM", @lobby_key, user_id]

  @doc """
  Creates a multiplayer match.
  """
  def create_match(user, data) do
    match_id = next_match_id()
    {match_id, _} = Integer.parse(match_id)

    query1 = [
      "HMSET",
      match_key(match_id),
      "in_progress", "false",
      "mods", "0",
      "match_name", data[:match_name],
      "match_password", data[:match_password],
      "beatmap_id", "#{data[:beatmap_id]}",
      "beatmap_name", data[:beatmap_name],
      "beatmap_md5", data[:beatmap_md5],
      "host_user_id", "#{user.id}",
      "game_mode", "#{data[:game_mode]}",
      "match_scoring_type", "#{@match_scoring_type_score}",
      "match_team_type", "#{@match_team_type_head_to_head}",
      "match_mod_mode", "#{@match_mod_mode_normal}",
      "seed", "0",
    ]

    slot_queries = for slot_id <- 0..15, do: [
      "HMSET",
      match_slot_key(match_id, slot_id),
      "slot_id", "#{slot_id}",
      "status", "#{@slot_status_free}",
      "team", "0",
      "user_id", "-1",
      "mods", "0",
      "loaded", "false",
      "skip", "false",
      "complete", "false",
    ]

    @client |> Exredis.query_pipe([query1 | slot_queries])

    stop_spectating(user.id, false)

    join_match(user, match_id, data[:match_password])

    set_match_host(match_id, user.id)

    lobby_user_ids = @client |> Exredis.query(["SMEMBERS", @lobby_key])
    match = match_data(match_id)
    for lobby_user_id <- lobby_user_ids, do: enqueue(lobby_user_id, Packet.create_match(match))
  end

  defp match_data(match_id) do
    query1 = [
      "HMGET",
      match_key(match_id),
      "in_progress",
      "mods",
      "match_name",
      "match_password",
      "beatmap_id",
      "beatmap_name",
      "beatmap_md5",
      "host_user_id",
      "game_mode",
      "match_scoring_type",
      "match_team_type",
      "match_mod_mode",
      "seed",
    ]

    slot_queries = for slot_id <- 0..15, do: [
      "HMGET",
      match_slot_key(match_id, slot_id),
      "slot_id",
      "status",
      "team",
      "user_id",
      "mods",
      "loaded",
      "skip",
      "complete",
    ]

    [
      [
        in_progress,
        mods,
        match_name,
        match_password,
        beatmap_id,
        beatmap_name,
        beatmap_md5,
        host_user_id,
        game_mode,
        match_scoring_type,
        match_team_type,
        match_mod_mode,
        seed,
      ] |
      slot_data,
    ] = @client |> Exredis.query_pipe([query1 | slot_queries])

    in_progress = string_to_bool(in_progress)
    {mods, _} = Integer.parse(mods)
    {beatmap_id, _} = Integer.parse(beatmap_id)
    {host_user_id, _} = Integer.parse(host_user_id)
    {game_mode, _} = Integer.parse(game_mode)
    {match_scoring_type, _} = Integer.parse(match_scoring_type)
    {match_team_type, _} = Integer.parse(match_team_type)
    {match_mod_mode, _} = Integer.parse(match_mod_mode)
    {seed, _} = Integer.parse(seed)

    match = [
      match_id: match_id,
      in_progress: in_progress,
      mods: mods,
      match_name: match_name,
      match_password: match_password,
      beatmap_id: beatmap_id,
      beatmap_name: beatmap_name,
      beatmap_md5: beatmap_md5,
      host_user_id: host_user_id,
      game_mode: game_mode,
      match_scoring_type: match_scoring_type,
      match_team_type: match_team_type,
      match_mod_mode: match_mod_mode,
      seed: seed,
    ]

    slots = for slot <- slot_data do
      [
        slot_id,
        status,
        team,
        user_id,
        mods,
        loaded,
        skip,
        complete,
      ] = slot

      {slot_id, _} = Integer.parse(slot_id)
      {status, _} = Integer.parse(status)
      {team, _} = Integer.parse(team)
      {user_id, _} = Integer.parse(user_id)
      {mods, _} = Integer.parse(mods)
      loaded = string_to_bool(loaded)
      skip = string_to_bool(skip)
      complete = string_to_bool(complete)

      [
        slot_id: slot_id,
        status: status,
        team: team,
        user_id: user_id,
        mods: mods,
        loaded: loaded,
        skip: skip,
        complete: complete,
      ]
    end

    match = [{:slots, slots} | match]

    match
  end

  defp string_to_bool(str) do
    case str do
      "true" -> true
      "false" -> false
      _ ->
        Logger.error "Unable to convert string \"#{str}\" to a bool"
        false
    end
  end

  @doc """
  """
  def change_match_settings(user, data) do
    match_name = data[:match_name]
    in_progress = data[:in_progress]
    beatmap_name = data[:beatmap_name]
    beatmap_id = data[:beatmap_id]
    host_user_id = data[:host_user_id]
    game_mode = data[:game_mode]
    mods = data[:mods]
    beatmap_md5 = data[:beatmap_md5]
    match_scoring_type = data[:scoring_type]
    match_team_type = data[:team_type]
    match_mod_mode = data[:free_mods]

    in_progress = case in_progress do
      0 ->
        "false"
      1 ->
        "true"
      _ ->
        Logger.error "#{Color.username(user.username)} attempted to update match settings, but provided an invalid in_progress value: #{in_progress}"
        "false"
    end

    # TODO: Compare data[:match_id] and the user's current match id
    match_id = data[:match_id]

    [old_mods, old_beatmap_md5] = @client |> Exredis.query([
      "HMGET", match_key(match_id),
      "mods", "beatmap_md5",
    ])

    case old_mods do
      :undefined ->
        Logger.error "#{Color.username(user.username)} attempted to update match settings, but the match appears to not exist"
      _ ->
        {old_mods, _} = Integer.parse(old_mods)

        query1 = [
          "HMSET", match_key(match_id),
          "match_name", match_name,
          "in_progress", in_progress,
          "beatmap_name", beatmap_name,
          "beatmap_id", beatmap_id,
          "host_user_id", host_user_id,
          "game_mode", game_mode,
          "mods", mods,
          "beatmap_md5", beatmap_md5,
          "match_scoring_type", match_scoring_type,
          "match_team_type", match_team_type,
          "match_mod_mode", match_mod_mode,
        ]

        queries = [query1]

        # Reset ready if needed
        queries = if old_mods != mods or old_beatmap_md5 != beatmap_md5 do
          slot_queries =
          for slot_id <- generate_slot_ids(),
              slot_status = @client |> Exredis.query(["HGET", match_slot_key(match_id, slot_id), "status"]),
              slot_status == "8" do
            ["HSET", match_slot_key(match_id, slot_id), "status", "#{@slot_status_not_ready}"]
          end

          queries ++ slot_queries
        else
          queries
        end

        # Reset mods if needed
        queries = if match_mod_mode == @match_mod_mode_normal do
          mod_queries = for slot_id <- generate_slot_ids() do
            ["HSET", match_slot_key(match_id, slot_id), "mods", "0"]
          end

          queries ++ mod_queries
        else
          # TODO: Possibly reset match mods if freemod?
          queries
        end

        # TODO: Teams

        # TODO: Tag coop

        @client |> Exredis.query_pipe(queries)

        send_multi_update(match_id)
    end
  end

  defp generate_slot_ids() do
    0..15
  end

  @doc """
  Changes a player's slot in a multiplayer match.
  """
  def change_slot(user, slot_id) do
    # TODO: Conflict resolution

    current_slot_id = @client |> Exredis.query([
      "HGET", "#{user_key(user.id)}",
      "slot_id",
    ])

    case current_slot_id do
      :undefined ->
        Logger.error "#{Color.username(user.username)} attempted to change their slot, but appears to be offline"
      "-1" ->
        Logger.error "#{Color.username(user.username)} attempted to change their slot, but doesn't seem to currently be in a slot"
      _ ->
        # (Unsafely?) assume that match_id will be well-defined
        match_id = @client |> Exredis.query([
          "HGET", "#{user_key(user.id)}",
          "match_id",
        ])
        {match_id, _} = Integer.parse(match_id)

        case @client |> Exredis.query(["HGET", match_slot_key(match_id, slot_id), "status"]) do
          :undefined ->
            Logger.error "#{Color.username(user.username)} attempted to change their slot, but the match doesn't appear to exist"
          "1" -> # @slot_status_free
            # Copy over current slot data
            [
              status,
              team,
              user_id,
              mods,
              loaded,
              skip,
              complete,
            ] = @client |> Exredis.query([
              "HMGET", match_slot_key(match_id, current_slot_id),
              "status",
              "team",
              "user_id",
              "mods",
              "loaded",
              "skip",
              "complete",
            ])

            query1 = [
              "HMSET", match_slot_key(match_id, slot_id),
              "status", status,
              "team", team,
              "user_id", user_id,
              "mods", mods,
              "loaded", loaded,
              "skip", skip,
              "complete", complete,
            ]
            query2 = set_slot_to_free_query(match_id, current_slot_id)
            query3 = [
              "HSET", user_key(user.id),
              "slot_id", "#{slot_id}",
            ]

            @client |> Exredis.query_pipe([query1, query2, query3])

            send_multi_update(match_id)
          _ ->
            Logger.error "#{Color.username(user.username)} attempted to change their slot, but the slot appears to be taken or locked"
        end
    end
  end

  @doc """
  Locks a slot in a multiplayer match.
  """
  def lock_match_slot(user, slot_id) do
    # TODO: Eliminate any data races

    case @client |> Exredis.query(["HGET", user_key(user.id), "match_id"]) do
      :undefined ->
        Logger.error "#{Color.username(user.username)} tried to lock slot #{slot_id}, but appears to be offline"
      "-1" ->
        Logger.error "#{Color.username(user.username)} tried to lock slot #{slot_id}, but appears to not be in a match"
      match_id ->
        {match_id, _} = Integer.parse(match_id)

        slot_status = @client |> Exredis.query(["HGET", match_slot_key(match_id, slot_id), "status"])
        case slot_status do
          :undefined ->
            Logger.error "#{Color.username(user.username)} tried to lock slot #{slot_id}, but the match appears to not exist"
          "1" ->
            Logger.warn "#{Color.username(user.username)} locked slot #{match_id}:#{slot_id}"
            @client |> Exredis.query(["HSET", match_slot_key(match_id, slot_id), "status", "#{@slot_status_locked}"])
            send_multi_update(match_id)
          "2" ->
            Logger.warn "#{Color.username(user.username)} unlocked slot #{match_id}:#{slot_id}"
            @client |> Exredis.query(["HSET", match_slot_key(match_id, slot_id), "status", "#{@slot_status_free}"])
            send_multi_update(match_id)
          _ ->
            Logger.error "#{Color.username(user.username)} tried to lock slot #{slot_id}, but the slot appears to be taken"
        end
    end
  end

  defp send_multi_update(match_id) do
    match_user_ids = @client |> Exredis.query(["SMEMBERS", match_users_key(match_id)])

    for match_user_id <- match_user_ids do
      enqueue(match_user_id, Packet.update_match(match_data(match_id)))
    end
  end

  @doc """
  Removes a user from a multiplayer match.
  """
  def part_match(user_id) do
    case @client |> Exredis.query(["HGET", user_key(user_id), "match_id"]) do
      :undefined ->
        :ok
      "-1" ->
        :ok
      match_id ->
        {match_id, _} = Integer.parse(match_id)
        if match_id == -1 do
          :ok
        else
          match_user_left(match_id, user_id)
        end
    end
  end

  defp set_slot_to_free_query(match_id, slot_id) do
    [
      "HMSET", match_slot_key(match_id, slot_id),
      "status", "#{@slot_status_free}",
      "team", "0",
      "user_id", "-1",
      "mods", "0",
      "loaded", "false",
      "skip", "false",
      "complete", "false",
    ]
  end

  defp match_user_left(match_id, user_id) do
    case get_user_slot_id(match_id, user_id) do
      nil ->
        Logger.error "Got a nil slot id when trying to remove a user from a match"
        :ok

      slot_id ->
        # set slot to free
        query1 = set_slot_to_free_query(match_id, slot_id)
        # remove from set of users in the match
        query2 = [
          "SREM", match_users_key(match_id),
          "#{user_id}",
        ]
        # update the leaver's match id to -1
        query3 = [
          "HSET", user_key(user_id),
          "match_id", "-1",
        ]
        @client |> Exredis.query_pipe([query1, query2, query3])

        queries = for slot_id <- 0..15 do
          ["HMGET", match_slot_key(match_id, user_id), "slot_id", "user_id"]
        end
        ret = @client |> Exredis.query_pipe(queries)
        players = for [slot_id, slot_user_id] <- ret, slot_user_id != "-1" do
          {slot_user_id, _} = Integer.parse(slot_user_id)
          slot_user_id
        end
        case players do
          [] ->
            dispose_match(match_id)
          [first_player_id | _] ->
            host_user_id = @client |> Exredis.query(["HGET", match_key(match_id), "host_user_id"])
            {host_user_id, _} = Integer.parse(host_user_id)
            if user_id == host_user_id do
              set_match_host(match_id, first_player_id)
            end
            # TODO: send update
            :ok
        end
        enqueue(user_id, Packet.channel_kicked("#multiplayer"))
    end
  end

  defp dispose_match(match_id) do
    keys_to_delete = [match_key(match_id) | (for slot_id <- 0..15 do
        match_slot_key(match_id, slot_id)
    end)]

    @client |> Exredis.query(["DEL" | keys_to_delete])
  end

  defp get_user_slot_id(match_id, user_id) do
    queries = for slot_id <- 0..15 do
      ["HMGET", match_slot_key(match_id, slot_id ), "slot_id", "user_id"]
    end
    ret = @client |> Exredis.query_pipe(queries)

    found = for [slot_id, slot_user_id] <- ret, slot_user_id != :undefined and elem(Integer.parse(slot_user_id), 0) == user_id do
      slot_id
    end

    case found do
      [slot_id] ->
        {slot_id, _} = Integer.parse(slot_id)
        slot_id
      [] ->
        Logger.error "Couldn't find #{user_id} in #{match_id} slots: #{inspect ret}"
        nil
      [slot_id | _] ->
        Logger.error "Found multiple instances of the same user id in match slots"
        # TODO: Correct the state
        {slot_id, _} = Integer.parse(slot_id)
        slot_id
    end
  end

  @doc """
  Joins a user into a multiplayer match.
  """
  def join_match(user, match_id, password) do
    # TODO: Leave other matches
    # TODO: Stop spectating

    # TODO: Make sure the match exists

    # TODO: Check password

    match = match_data(match_id)
    free_slot = Enum.find(match[:slots], fn(slot) -> slot[:status] == @slot_status_free end)
    if not is_nil(free_slot) do
      query1 = [
        "HMSET",
        match_slot_key(match_id, "#{free_slot[:slot_id]}"),
        "status", "#{@slot_status_not_ready}",
        "team", "0",
        "user_id", "#{user.id}",
        "mods", "0",
      ]
      query2 = [
        "HMSET",
        user_key(user.id),
        "match_id", "#{match_id}",
        "slot_id", "#{free_slot[:slot_id]}",
      ]
      query3 = [
        "SADD", match_users_key(match_id),
        "#{user.id}",
      ]
      @client |> Exredis.query_pipe([query1, query2, query3])

      # TODO: Send update to users

      enqueue(user.id, Packet.match_join_success(match))
      enqueue(user.id, Packet.channel_join_success("#multiplayer"))

      true
    else
      Logger.error "#{user.username} couldn't join #{match_id}: no free slot"
      false
    end
  end

  @doc """
  Changes a player's mods in a multiplayer match.
  """
  def change_mods(user, mods) do
    query = ["HMGET", user_key(user.id), "match_id", "slot_id"]
    case @client |> Exredis.query(query) do
      [:undefined, :undefined] ->
        Logger.error "#{Color.username(user.username)} attempted to change their multiplayer mods, but appears to be offline"
      ["-1", "-1"] ->
        Logger.error "#{Color.username(user.username)} attempted to change their multiplayer mods, but appears to not be in a match"
      [match_id, slot_id] ->
        {match_id, _} = Integer.parse(match_id)
        {slot_id, _} = Integer.parse(slot_id)

        [match_mod_mode, host_user_id] = @client |> Exredis.query([
          "HMGET", match_key(match_id),
          "match_mod_mode", "host_user_id",
        ])
        {match_mod_mode, _} = Integer.parse(match_mod_mode)
        {host_user_id, _} = Integer.parse(host_user_id)

        change_own_mod_query = [
          "HSET",
          match_slot_key(match_id, slot_id),
          "mods", "#{mods}",
        ]

        queries = if host_user_id == user.id do
          match_mods = if match_mod_mode == @match_mod_mode_free_mod do
            # DT, HT, NC
            mods &&& (64 ||| 256 ||| 512)
          else
            mods
          end
          query = ["HSET", match_key(match_id), "mods", "#{match_mods}"]
          [query, change_own_mod_query]
        else
          if match_mod_mode == @match_mod_mode_free_mod do
            [change_own_mod_query]
          else
            []
          end
        end

        @client |> Exredis.query_pipe(queries)

        send_multi_update(match_id)
    end
  end

  def match_skip_request(user) do
    [match_id, slot_id] = @client |> Exredis.query([
      "HMGET", user_key(user.id),
      "match_id", "slot_id",
    ])

    case match_id do
      :undefined ->
        Logger.error "#{Color.username(user.username)} attempted to skip during a match, but appears to be offline"
      "-1" ->
        Logger.error "#{Color.username(user.username)} attempted to skip during a match, but appears to not be in a match"
      _ ->
        {match_id, _} = Integer.parse(match_id)
        {slot_id, _} = Integer.parse(slot_id)

        @client |> Exredis.query([
          "HSET", match_slot_key(match_id, slot_id),
          "skip", "true",
        ])

        queries = for slot_id <- generate_slot_ids() do
          ["HMGET", match_slot_key(match_id, slot_id), "skip", "status", "user_id"]
        end

        # send skip packet to all playing users
        for [_, "32", user_id] <- @client |> Exredis.query_pipe(queries) do
          {user_id, _} = Integer.parse(user_id)
          enqueue(user_id, Packet.player_skipped(user_id))
        end

        # count players who haven't skipped and are playing
        yet_to_skip = for ["false", "32", _] <- @client |> Exredis.query_pipe(queries), do: :ok
        if length(yet_to_skip) == 0 do
          for [_, "32", user_id] <- @client |> Exredis.query_pipe(queries) do
            {user_id, _} = Integer.parse(user_id)
            enqueue(user_id, Packet.all_players_skipped())
          end
        end
    end
  end

  def match_start(user) do
    # TODO: Error checking

    match_id = @client |> Exredis.query(["HGET", user_key(user.id), "match_id"])

    case match_id do
      :undefined ->
        Logger.error "#{Color.username(user.username)} attempted to start a match, but appears to be offline"
      "-1" ->
        Logger.error "#{Color.username(user.username)} attempted to start a match, but appears to not be in a match"
      _ ->
        {match_id, _} = Integer.parse(match_id)

        @client |> Exredis.query(["HSET", match_key(match_id), "in_progress", "true"])

        queries = for slot_id <- generate_slot_ids() do
          ["HMGET", match_slot_key(match_id, slot_id), "slot_id", "status", "user_id"]
        end

        update_queries = for [slot_id, "8", _] <- @client |> Exredis.query_pipe(queries) do
          # ready players
          {slot_id, _} = Integer.parse(slot_id)
          [
            "HMSET", match_slot_key(match_id, slot_id),
            "status", "#{@slot_status_playing}",
            "loaded", "false",
            "skip", "false",
            "complete", "false",
          ]
        end

        for [_, "32", user_id] <- @client |> Exredis.query_pipe(queries) do
          {user_id, _} = Integer.parse(user_id)
          # TODO: Pipelining
          enqueue(user_id, Packet.match_start(match_data(match_id)))
        end

        send_multi_update(match_id)
    end

  end

  def match_ready(user) do
    query = ["HMGET", user_key(user.id), "match_id", "slot_id"]
    case @client |> Exredis.query(query) do
      [:undefined, :undefined] ->
        Logger.error "#{Color.username(user.username)} attempted to ready for match, but appears to be offline"
      ["-1", "-1"] ->
        Logger.error "#{Color.username(user.username)} attempted to ready for match, but appears to not be in a match"
      [match_id, slot_id] ->
        {match_id, _} = Integer.parse(match_id)
        {slot_id, _} = Integer.parse(slot_id)

        # TODO: Error checking
        @client |> Exredis.query(["HSET", match_slot_key(match_id, slot_id), "status", "#{@slot_status_ready}"])
    end
  end

  def match_not_ready(user) do
    query = ["HMGET", user_key(user.id), "match_id", "slot_id"]
    case @client |> Exredis.query(query) do
      [:undefined, :undefined] ->
        Logger.error "#{Color.username(user.username)} attempted to ready for match, but appears to be offline"
      ["-1", "-1"] ->
        Logger.error "#{Color.username(user.username)} attempted to ready for match, but appears to not be in a match"
      [match_id, slot_id] ->
        {match_id, _} = Integer.parse(match_id)
        {slot_id, _} = Integer.parse(slot_id)

        # TODO: Error checking
        @client |> Exredis.query(["HSET", match_slot_key(match_id, slot_id), "status", "#{@slot_status_not_ready}"])
    end
  end

  def match_frames(user, data) do
    query = ["HMGET", user_key(user.id), "match_id", "slot_id"]
    case @client |> Exredis.query(query) do
      [:undefined, :undefined] ->
        Logger.error "#{Color.username(user.username)} attempted to send match frames, but appears to be offline"
      ["-1", "-1"] ->
        Logger.error "#{Color.username(user.username)} attempted to send match frames, but appears to not be in a match"
      [match_id, slot_id] ->
        {match_id, _} = Integer.parse(match_id)
        {slot_id, _} = Integer.parse(slot_id)

        # TODO: Error checking

        queries = for slot_id <- generate_slot_ids() do
          ["HMGET", match_slot_key(match_id, slot_id), "status", "user_id"]
        end
        # Enqueue frames to whoever is playing
        packet = Packet.match_frames(slot_id, data)
        for ["32", user_id] <- @client |> Exredis.query_pipe(queries) do
          {user_id, _} = Integer.parse(user_id)
          # TODO: Pipeline
          enqueue(user_id, packet)
        end
    end
  end

  def match_has_beatmap(user, has) do
    query = ["HMGET", user_key(user.id), "match_id", "slot_id"]
    case @client |> Exredis.query(query) do
      [:undefined, :undefined] ->
        Logger.error "#{Color.username(user.username)} attempted to send has beatmap #{has}, but appears to be offline"
      ["-1", "-1"] ->
        Logger.error "#{Color.username(user.username)} attempted to send has beatmap #{has}, but appears to not be in a match"
      [match_id, slot_id] ->
        {match_id, _} = Integer.parse(match_id)
        {slot_id, _} = Integer.parse(slot_id)

        # TODO: Error checking

        query = ["HSET", match_slot_key(match_id, slot_id), "status", "#{if has do @slot_status_not_ready else @slot_status_no_map end}"]
        @client |> Exredis.query(query)

        send_multi_update(match_id)
    end
  end

  def match_complete(user) do
    query = ["HMGET", user_key(user.id), "match_id", "slot_id"]
    case @client |> Exredis.query(query) do
      [:undefined, :undefined] ->
        Logger.error "#{Color.username(user.username)} attempted to complete match, but appears to be offline"
      ["-1", "-1"] ->
        Logger.error "#{Color.username(user.username)} attempted to complete match, but appears to not be in a match"
      [match_id, slot_id] ->
        {match_id, _} = Integer.parse(match_id)
        {slot_id, _} = Integer.parse(slot_id)

        # TODO: Error checking

        query = [
          "HSET",
          match_slot_key(match_id, slot_id),
          "complete", "true",
        ]
        @client |> Exredis.query(query)

        queries = for slot_id <- generate_slot_ids() do
          ["HMGET", match_slot_key(match_id, slot_id), "complete", "status"]
        end

        still_playing = for ["false", "32"] <- @client |> Exredis.query_pipe(queries), do: :ok

        if length(still_playing) == 0 do
          all_players_completed(match_id)
        end
    end
  end

  defp all_players_completed(match_id) do
    update_queries = [["HSET", match_key(match_id), "in_progress", "true"]]

    queries = for slot_id <- generate_slot_ids() do
      ["HMGET", match_slot_key(match_id, slot_id), "slot_id", "status"]
    end

    update_queries = update_queries ++ for [slot_id, "32"] <- @client |> Exredis.query_pipe(queries) do
      {slot_id, _} = Integer.parse(slot_id)
      [
        "HMSET", match_slot_key(match_id, slot_id),
        "status", "#{@slot_status_not_ready}",
        "loaded", "false",
        "skip", "false",
        "complete", "false",
      ]
    end

    @client |> Exredis.query_pipe(update_queries)

    queries = for slot_id <- generate_slot_ids() do
      ["HGET", match_slot_key(match_id, slot_id), "user_id"]
    end

    for user_id <- @client |> Exredis.query_pipe(queries) do
      # TODO: Pipeline
      {user_id, _} = Integer.parse(user_id)
      enqueue(user_id, Packet.match_complete())
    end

    send_multi_update(match_id)
  end

  defp all_players_loaded(match_id) do
    queries = for slot_id <- generate_slot_ids() do
      ["HMGET", match_slot_key(match_id, slot_id), "user_id", "status"]
    end

    for [user_id, "32"] <- @client |> Exredis.query_pipe(queries) do
      # TODO: Pipeline
      {user_id, _} = Integer.parse(user_id)
      enqueue(user_id, Packet.all_players_loaded())
    end
  end

  def match_load_complete(user) do
    query = ["HMGET", user_key(user.id), "match_id", "slot_id"]
    case @client |> Exredis.query(query) do
      [:undefined, :undefined] ->
        Logger.error "#{Color.username(user.username)} attempted to load into match, but appears to be offline"
      ["-1", "-1"] ->
        Logger.error "#{Color.username(user.username)} attempted to load into match, but appears to not be in a match"
      [match_id, slot_id] ->
        {match_id, _} = Integer.parse(match_id)
        {slot_id, _} = Integer.parse(slot_id)

        # TODO: Error checking

        query = [
          "HSET",
          match_slot_key(match_id, slot_id),
          "loaded", "true",
        ]
        @client |> Exredis.query(query)

        queries = for slot_id <- generate_slot_ids() do
          ["HMGET", match_slot_key(match_id, slot_id), "loaded", "status"]
        end

        still_loading = for ["false", "32"] <- @client |> Exredis.query_pipe(queries), do: :ok

        if length(still_loading) == 0 do
          all_players_loaded(match_id)
        end
    end
  end

  @doc """
  Sets a user as the host of a multiplayer match.
  """
  def set_match_host(match_id, user_id) do
    @client |> Exredis.query(["HSET", match_key(match_id), "host_user_id", "#{user_id}"])
    enqueue(user_id, Packet.match_transfer_host())
  end

  defp next_match_id() do
    @client |> Exredis.query(["INCR", "next_match_id"])
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

  defp user_login_key(user_id) do
    "user.login:#{user_id}"
  end

  # Constructs the Redis key for a channel
  defp channel_key(channel) do
    "channel:#{channel}"
  end

  defp match_key(match_id) do
    "match:#{match_id}"
  end

  defp match_slot_key(match_id, slot_id) do
    "match.slot:#{match_id}:#{slot_id}"
  end

  defp match_users_key(match_id) do
    "match.users:#{match_id}"
  end
end
