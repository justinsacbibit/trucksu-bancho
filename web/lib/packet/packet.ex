defmodule Game.Packet do
  require Logger
  use Bitwise

  alias Game.Packet.Ids
  alias Game.StateServer
  alias Trucksu.{
    Repo,
    User,
    UserStats,
  }
  alias Game.TruckLord
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
    <<0x0b>> <> encode(byte_size(data)) <> data
  end

  def encode(value), do: encode_leb128(value, 0, <<>>)

  defp encode_leb128(value, shift, acc) when (value >>> shift) < 128 do
    chunk = value >>> shift
    <<acc::binary, chunk::unsigned-little-size(8)>>
  end

  defp encode_leb128(value, shift, acc) do
    chunk = value >>> shift
    encode_leb128(value, shift + 7, <<acc::binary, (chunk ||| 128)::unsigned-little-size(8)>>)
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

    #if TruckLord.is_online? do
    #  user_ids = [TruckLord.user_id | user_ids]
    #end

    data = [{length(user_ids), :int16}]

    data = data ++ Enum.map(user_ids, &({&1, :int32}))

    new(Ids.server_userPresenceBundle, data)
  end

  def user_panel(user) do
    trucklord_user_id = TruckLord.user_id
    case user.id do
      #^trucklord_user_id ->
      #  user_panel(user, nil)
      _ ->
        case StateServer.Client.action(user.id) do
          nil ->
            Logger.warn "user_panel/1 , offline"
            <<>>
          :bot ->
            user_panel(user, nil)
          action ->
            user_panel(user, action)
        end
    end
  end
  def user_panel(user, action) do
    trucklord_user_id = TruckLord.user_id
    case user.id do
      ^trucklord_user_id ->
        new(Ids.server_userPanel, [
          {user.id, :uint32},
          {user.username, :string},
          {0, :uint8},
          {0, :uint8},
          {4, :uint8},
          {0.0, :float},
          {0.0, :float},
          {0, :uint32},
        ])

      _ ->
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
           FROM (
             SELECT us.*
             FROM user_stats us
             JOIN users u
               ON u.id = us.user_id
             WHERE u.banned = FALSE
              AND us.game_mode = (?)
           ) sc) sc
        WHERE user_id = (?)
      ", ^game_mode, ^user_id),
        on: s.id == s_.id,
      select: {s, s_.game_rank}
  end

  def user_presence_single(user_id) do
    new(Ids.server_userPresenceSingle, [
      {user_id, :int32}
    ])
  end

  def user_stats(user) do
    case StateServer.Client.action(user.id) do
      nil ->
        Logger.warn "user_stats/1 , offline"
        <<>>
      :bot ->
        <<>>
      action -> user_stats(user, action)
    end
  end
  def user_stats(user, action) do
    trucklord_user_id = TruckLord.user_id
    case user.id do
      ^trucklord_user_id ->
        #Logger.error "not sending user_stats for trucklord"
        new(Ids.server_userStats, [
          {user.id, :uint32},
          {0, :uint8},
          {"", :string},
          {"", :string},
          {"", :int32},
          {"", :uint8},
          {0, :int32},
          {0, :uint64},
          {0.0, :float},
          {0, :uint32},
          {0, :uint64},
          {0, :uint32},
          {0, :uint16},
        ])
        #<<>>
      _ ->
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

  ## Multiplayer packets

  def create_match(data) do
    new(Ids.server_newMatch, mp_packet_data(data))
  end

  def update_match(data) do
    new(Ids.server_updateMatch, mp_packet_data(data))
  end

  def match_start(data) do
    new(Ids.server_matchStart, mp_packet_data(data))
  end

  def dispose_match(match_id) do
    new(Ids.server_disposeMatch, [{match_id, :uint32}])
  end

  def match_join_success(data) do
    new(Ids.server_matchJoinSuccess, mp_packet_data(data))
  end

  def match_join_fail() do
    new(Ids.server_matchJoinFail, [])
  end

  def change_match_password(new_password) do
    new(Ids.server_matchChangePassword, [{new_password, :string}])
  end

  def all_players_loaded() do
    new(Ids.server_matchAllPlayersLoaded, [])
  end

  def player_skipped(user_id) do
    new(Ids.server_matchPlayerSkipped, [{user_id, :int32}])
  end

  def all_players_skipped() do
    new(Ids.server_matchSkip, [])
  end

  def match_frames(slot_id, data) do
    # First, split the data. Separate out the first 4 bytes
    <<first::binary-size(4), _::binary-size(1), rest::binary>> = data

    # The slot id goes between the data sections
    new(Ids.server_matchScoreUpdate, [{first, :bytes}, {slot_id, :int8}, {rest, :bytes}])
  end

  def match_complete() do
    new(Ids.server_matchComplete, [])
  end

  def player_failed(slot_id) do
    new(Ids.server_matchPlayerFailed, [{slot_id, :uint32}])
  end

  def match_transfer_host() do
    # TODO: Automatic transfer host when host leaves
    new(Ids.server_matchTransferHost, [])
  end

  # Converts a keyword list of data into the proper packet format
  defp mp_packet_data(data) do
    packed_data = [
      {data[:match_id], :uint16},
      {if data[:in_progress] do 1 else 0 end, :int8},
      {0, :int8},
      {data[:mods], :uint32},
      {data[:match_name], :string},
      {data[:match_password], :string},
      {data[:beatmap_name], :string},
      {data[:beatmap_id], :uint32},
      {data[:beatmap_md5], :string},
    ]

    packed_slot_data = (for slot_data <- data[:slots] do
      {slot_data[:status], :int8}
    end) ++ (for slot_data <- data[:slots] do
      {slot_data[:team], :int8}
    end) ++ (for slot_data <- data[:slots], slot_data[:user_id] != -1 do
      {slot_data[:user_id], :uint32}
    end)

    packed_data = packed_data ++ packed_slot_data

    packed_data = packed_data ++ [
      {data[:host_user_id], :int32},
      {data[:game_mode], :int8},
      {data[:match_scoring_type], :int8},
      {data[:match_team_type], :int8},
      {data[:match_mod_mode], :int8},
    ]

    packed_data = packed_data ++ (for slot_data <- data[:slots], data[:match_mod_mode] == StateServer.Client.match_mod_mode_free_mod do
      {slot_data[:mods], :uint32}
    end)

    packed_data = packed_data ++ [{data[:seed], :uint32}]

    packed_data
  end
end
