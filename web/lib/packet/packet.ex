defmodule Game.Packet do
  require Logger
  alias Game.Packet.Ids
  alias Game.StateServer
  alias Trucksu.{
    Repo,
    User,
    UserStats,
  }
  import Ecto.Query, only: [from: 2]

  defp pack_num(int, size, signed) when is_integer(int) and is_integer(size) do
    if signed do
      <<int::little-size(size)>>
    else
      <<int::unsigned-little-size(size)>>
    end
  end

  defp pack_num(float) when is_float(float) do
    <<float::little-float-size(32)>>
  end

  defp pack(data, :uint64), do: pack_num(data, 64, false)
  defp pack(data, :uint32), do: pack_num(data, 32, false)
  defp pack(data, :uint16), do: pack_num(data, 16, false)
  defp pack(data, :uint8), do: pack_num(data, 8, false)
  defp pack(data, :int32), do: pack_num(data, 32, true)
  defp pack(data, :int16), do: pack_num(data, 16, true)
  defp pack(data, :int8), do: pack_num(data, 8, true)
  defp pack(data, :float), do: pack_num(data)
  defp pack(data, :bytes), do: data
  defp pack("", :string) do
    <<0>>
  end
  defp pack(data, :string) do
    <<0x0b>> <> pack(byte_size(data), :uint8) <> data
  end

  def new(id, data_list) do
    reduce_func = fn({data, type}, acc) -> acc <> pack(data, type) end
    data = Enum.reduce(data_list, <<>>, reduce_func)
    pack(id, :uint16) <> <<0>> <> pack(byte_size(data), :uint32) <> data
  end

  def login_failed, do: new(Ids.server_userID, [{-1, :int32}])
  def needs_update, do: new(Ids.server_userID, [{-2, :int32}])
  def banned, do: new(Ids.server_userID, [{-3, :int32}])
  def banned2, do: new(Ids.server_userID, [{-4, :int32}])
  def server_login_error, do: new(Ids.server_userID, [{-5, :int32}])
  def need_supporter, do: new(Ids.server_userID, [{-6, :int32}])
  def password_reset, do: new(Ids.server_userID, [{-7, :int32}])
  def verify_identity, do: new(Ids.server_userID, [{-8, :int32}])
  def user_id(id), do: new(Ids.server_userID, [{id, :int32}])
  def silence_end_time(seconds), do: new(Ids.server_silenceEnd, [{seconds, :uint32}])

  def logout(user_id) do
    new(Ids.server_userLogout, [{user_id, :uint32}, {0, :uint8}])
  end

  def protocol_version(version \\ 19) do
    new(Ids.server_protocolVersion, [{version, :int32}])
  end

  def main_menu_icon(icon), do: new(Ids.server_mainMenuIcon, [{icon, :string}])

  def user_supporter_gmt(supporter, gmt) do
    result = 1

    result = result + if supporter do
      4
    else
      0
    end

    result = result + if gmt do
      2
    else
      0
    end

    new(Ids.server_supporterGMT, [{result, :uint32}])
  end

  @doc """
  Constructs a packet that contains a user's friend list.

  Preloads the user's friends from the database.
  """
  def friends_list(user) do
    user = Repo.preload user, :friends

    data = [{length(user.friends), :int16}]

    data = data ++
      for %User{id: id} <- user.friends,
        do: {id, :int32}

    new(Ids.server_friendsList, data)
  end

  def online_users do
    user_ids = StateServer.Client.user_ids()

    data = [{length(user_ids), :int16}]

    data = data ++ Enum.map(user_ids, &({&1, :int32}))

    new(Ids.server_userPresenceBundle, data)
  end

  def user_panel(user) do
    case StateServer.Client.action(user.id) do
      nil -> <<>>
      action -> user_panel(user, action)
    end
  end
  def user_panel(user, action) do
    {[latitude, longitude], country_id} = StateServer.Client.user_location(user.id)

    # TODO: timezone
    timezone = 24
    user_rank = 0 # normal

    user_id = user.id
    game_mode = action[:game_mode]

    # TODO: Remove
    if is_nil(game_mode) do
      Logger.error "Packet.user_panel/2: game_mode is nil for #{user.username}"
      Logger.error "Action data: #{inspect action}"
    end

    case stats_and_rank(user_id, game_mode) do
        nil ->
          <<>>
        {_stats, game_rank} ->
          new(Ids.server_userPanel, [
            {user.id, :uint32},
            {user.username, :string},
            {timezone, :uint8},
            {country_id, :uint8},
            {user_rank, :uint8},
            {longitude, :float},
            {latitude, :float},
            {game_rank, :uint32},
          ])
    end
  end

  defp stats_and_rank(user_id, game_mode) do
    # TODO: Figure out why game_mode is nil sometimes
    game_mode = game_mode || 0
    Repo.one from s in UserStats,
      join: s_ in fragment("
        SELECT game_rank, id
        FROM
          (SELECT
             row_number()
             OVER (
               ORDER BY pp DESC) game_rank,
             user_id, id
           FROM
             (SELECT * FROM user_stats us
               WHERE us.game_mode = (?)
             ) sc) sc
        WHERE user_id = (?)
      ", ^game_mode, ^user_id),
        on: s.id == s_.id,
      select: {s, s_.game_rank}
  end

  def user_stats(user) do
    case StateServer.Client.action(user.id) do
      nil -> <<>>
      action -> user_stats(user, action)
    end
  end
  def user_stats(user, action) do
    user_id = user.id
    game_mode = action[:game_mode]

    # TODO: Remove
    if is_nil(game_mode) do
      Logger.error "Packet.user_stats/2: game_mode is nil for #{user.username}"
      Logger.error "Action data: #{inspect action}"
    end

    case stats_and_rank(user_id, game_mode) do
        nil ->
          <<>>
        {stats, game_rank} ->
          new(Ids.server_userStats, [
            {user.id, :uint32},
            {action[:action_id], :uint8},
            {action[:action_text], :string},
            {action[:action_md5], :string},
            {action[:action_mods], :int32},
            {action[:game_mode], :uint8},
            {0, :int32},
            {stats.ranked_score, :uint64},
            {stats.accuracy, :float},
            {stats.playcount, :uint32},
            {stats.total_score, :uint64},
            {game_rank, :uint32},
            {round(stats.pp), :uint16},
          ])
    end
  end

  @channels %{
    "#osu" => "General Chat",
    "#announce" => "Announcements",
  }

  def channel_info(key) do
    new(Ids.server_channelInfo, [
      {key, :string},
      {@channels[key], :string},
      {0, :uint16},
    ])
  end

  def send_message(from, message, to, from_user_id) do
    new(Ids.server_sendMessage, [
      {from, :string},
      {message, :string},
      {to, :string},
      {from_user_id, :int32},
    ])
  end

  def channel_info_end do
    new(Ids.server_channelInfoEnd, [{0, :uint32}])
  end

  def channel_join_success(channel_name) do
    new(Ids.server_channelJoinSuccess, [{channel_name, :string}])
  end

  def channel_kicked(channel_name) do
    new(Ids.server_channelKicked, [{channel_name, :string}])
  end

  def server_restart(ms_until_reconnect) do
    new(Ids.server_restart, [{ms_until_reconnect, :uint32}])
  end

  def notification(message) do
    new(Ids.server_notification, [{message, :string}])
  end

  def jumpscare(message) do
    new(Ids.server_jumpscare, [{message, :string}])
  end

  ## Spectator packets

  def add_spectator(user_id) do
    new(Ids.server_spectatorJoined, [{user_id, :int32}])
  end

  def remove_spectator(user_id) do
    new(Ids.server_spectatorLeft, [{user_id, :int32}])
  end

  def spectator_frames(data) do
    new(Ids.server_spectateFrames, [{data, :bytes}])
  end

  def no_song_spectator(user_id) do
    new(Ids.server_spectatorCantSpectate, [{user_id, :int32}])
  end
end
