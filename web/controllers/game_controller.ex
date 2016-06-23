defmodule Game.GameController do
  use Game.Web, :controller
  import Ecto.Query, only: [from: 2]
  require Logger
  alias Game.{
    Packet,
    StateServer,
    Utils,
    TruckLord,
  }
  alias Trucksu.{
    Session,

    Repo,
    Friendship,
    KnownIp,
    User,
  }
  alias Game.Utils.Color

  plug :get_token
  plug :get_body
  plug :get_request_ip
  plug :get_request_location

  defp get_token(conn, _) do
    osu_token = Plug.Conn.get_req_header(conn, "osu-token")
    assign(conn, :osu_token, osu_token)
  end

  defp get_body(conn, _) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    assign(conn, :body, body)
  end

  defp get_request_ip(conn, _) do
    request_ip = case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [request_ip] -> request_ip
      _ -> "0.0.0.0"
    end

    assign(conn, :request_ip, request_ip)
  end

  defp get_request_location(conn, _) do
    osu_token = conn.assigns[:osu_token]
    case osu_token do
      [] ->
        request_ip = conn.assigns[:request_ip]

        result = if Application.get_env(:game, :get_request_location) do
          with {:ok, %HTTPoison.Response{body: body}} <- HTTPoison.get("http://ip-api.com/json/#{request_ip}"),
               {:ok, %{"countryCode" => country_code, "lat" => lat, "lon" => lon}} <- Poison.decode(body),
               do: {:location, {[lat, lon], country_code}}
        else
          nil
        end

        case result do
          {:location, {location, country_code}} ->
            conn
            |> assign(:location, location)
            |> assign(:country_code, country_code)
          _ ->
            conn
            |> assign(:location, [0.0, 0.0])
            |> assign(:country_code, "BL")
        end
      _ ->

        # Don't get the request location if the user is already logged in
        conn
    end
  end


  def index(conn, _params) do
    osu_token = conn.assigns[:osu_token]
    body = conn.assigns[:body]
    handle_request(conn, body, osu_token)
  end

  def send_packet(packet_id, data, user) do
    handle_packet(packet_id, data, user)
  end

  defp handle_request(conn, body, []) do
    [username, hashed_password, extra | _] = String.split(body, "\n")
    [_, timezone | _] = String.split(extra, "|")

    Logger.warn "Received login request for #{username}"

    case Session.authenticate(username, hashed_password, true) do
      {:ok, %User{banned: false} = user} ->
        {:ok, jwt, _full_claims} = user |> Guardian.encode_and_sign(:token)

        request_ip = conn.assigns[:request_ip]
        case Repo.get_by KnownIp, ip_address: request_ip, user_id: user.id do
          nil ->
            changeset = KnownIp.changeset(%KnownIp{}, %{ip_address: request_ip, user_id: user.id})
            case Repo.insert changeset do
              {:ok, _} ->
                Logger.warn "Saved new IP address #{request_ip} for #{Color.username(user.username)}"
              {:error, error} ->
                Logger.error "Unable to save new IP address #{request_ip} for #{Color.username(user.username)}"
                Logger.error inspect error
            end
          _ ->
            :ok
        end

        location = conn.assigns[:location]
        country_code = conn.assigns[:country_code]

        timezone = case Integer.parse(timezone) do
          {timezone, _} -> timezone
          _ -> 0
        end
        changeset = Ecto.Changeset.change user, %{country: country_code, timezone: timezone}
        user = Repo.update! changeset

        StateServer.Client.add_user(user, jwt, location, Utils.country_id(country_code))

        render prepare_conn(conn, jwt), "response.raw", data: login_packets(user)
      {:ok, user} ->
        Logger.warn "Login failed for banned user #{Color.username(username)}"
        render prepare_conn(conn), "response.raw", data: Packet.login_failed
      {:error, reason} ->
        Logger.warn "Login failed for #{Color.username(username)}. Reason: #{reason}"
        render prepare_conn(conn), "response.raw", data: Packet.login_failed
    end
  end

  defp handle_request(conn, stacked_packets, [osu_token]) do
    data = case Guardian.decode_and_verify(osu_token) do
      {:ok, claims} ->

        # TODO: Consider preventing SQL queries when it is a pong packet
        #       and the packet queue is empty
        {:ok, user} = Guardian.serializer.from_token(claims["sub"])

        StateServer.Client.update_last_request_time(user.id)

        # TODO: Return an error if the user is somehow not in the state

        decoded_packets = Packet.Decoder.decode_packets(stacked_packets)

        Logger.debug inspect(decoded_packets)

        data = decoded_packets
        |> Enum.reduce(<<>>, fn({packet_id, data}, acc) ->
          packet_response = handle_packet(packet_id, data, user)

          if is_nil(packet_response) do
            Logger.error "nil packet response for #{packet_id}: #{inspect data}"
            Logger.error "#{inspect user}"

            packet_response = <<>>
          end

          acc <> packet_response
        end)

        packet_queue = StateServer.Client.dequeue(user.id)
        data <> Enum.reduce(packet_queue, <<>>, fn(packet, acc) ->
          acc <> packet
        end)

      {:error, _reason} ->
        Packet.login_failed
    end

    render prepare_conn(conn, osu_token), "response.raw", data: data
  end

  defp handle_packet(0, data, user) do
    case data[:action_id] do
      0 -> :ok
      _ ->
        Logger.warn "changeAction for #{Color.username(user.username)}: #{inspect Enum.map(data, &(elem(&1, 1)))}"
    end

    StateServer.Client.change_action(user, data)

    <<>>
  end

  defp handle_packet(1, data, user) do
    channel_name = data[:to]
    Logger.warn "#{Color.username(user.username)} to #{Color.channel(channel_name)}: #{data[:message]}"

    packet = Packet.send_message(user.username, data[:message], channel_name, user.id)
    # TODO: Extract the case statement into the StateServer?
    case channel_name do
      "#spectator" ->
        StateServer.Client.send_spectator_message(packet, user.id)
      "#multiplayer" ->
        StateServer.Client.send_multiplayer_message(packet, user)
      _ ->
        StateServer.Client.send_public_message(channel_name, packet, user.id)
    end

    <<>>
  end

  defp handle_packet(2, _data, user) do
    if StateServer.Client.recently_logged_in?(user.id) do
      Logger.warn "Ignoring logout for #{Color.username(user.username)}"
    else
      Logger.warn "Handling logout for #{Color.username(user.username)}"
      StateServer.Client.remove_user(user.id)
    end

    <<>>
  end

  defp handle_packet(3, _data, user) do
    Logger.info "#{Color.username(user.username)}!requestStatusUpdate"
    user_panel_packet = Packet.user_panel(user)
    user_stats_packet = Packet.user_stats(user)

    user_panel_packet <> user_stats_packet
  end

  defp handle_packet(4, _data, _user) do
    <<>>
  end

  defp handle_packet(16, data, user) do
    host_id = data[:user_id]
    case Repo.get User, host_id do
      nil ->
        Logger.error "#{Color.username(user.username)}!startSpectating a user that does not exist: #{host_id}"
      host ->
        Logger.warn "#{Color.username(user.username)}!startSpectating #{host.username}"

        StateServer.Client.spectate(user.id, host_id)
    end

    <<>>
  end

  defp handle_packet(17, _data, user) do
    Logger.warn "#{Color.username(user.username)}!stopSpectating"

    StateServer.Client.stop_spectating(user.id)

    <<>>
  end

  defp handle_packet(18, data, user) do
    # Logger.warn "#{Color.username(user.username)}!spectateFrames"

    StateServer.Client.spectate_frames(user.id, data[:data])

    <<>>
  end

  defp handle_packet(21, _data, user) do
    Logger.warn "#{Color.username(user.username)}!cantSpectate"

    StateServer.Client.cant_spectate(user.id)

    <<>>
  end

  defp handle_packet(25, data, user) do

    to_username = data[:to]
    message = data[:message]

    trucklord_username = TruckLord.username
    case to_username do
      ^trucklord_username ->
        TruckLord.receive_message(message, user)

      _ ->
        Logger.warn "#{Color.username(user.username)} to #{Color.username(data[:to])}: #{data[:message]}"

        # TODO: Fix lack of "this user is offline" message when the user is offline"
        packet = Packet.send_message(user.username, message, to_username, user.id)

        StateServer.Client.enqueue_for_username(to_username, packet)
    end


    <<>>
  end

  defp handle_packet(29, _data, user) do
    Logger.warn "#{Color.username(user.username)}!partLobby"

    StateServer.Client.part_lobby(user.id)

    <<>>
  end

  defp handle_packet(30, _data, user) do
    Logger.warn "#{Color.username(user.username)}!joinLobby"

    StateServer.Client.join_lobby(user.id)

    <<>>
  end

  defp handle_packet(31, data, user) do
    Logger.warn "#{Color.username(user.username)}!createMatch: \"#{data[:match_name]}\""

    StateServer.Client.create_match(user, data)

    <<>>
  end

  defp handle_packet(32, data, user) do
    Logger.warn "#{Color.username(user.username)}!joinMatch: match_id=#{data[:match_id]} password=#{data[:password]}"

    StateServer.Client.join_match(user, data[:match_id], data[:password])
  end

  defp handle_packet(33, _data, user) do
    Logger.warn "#{Color.username(user.username)}!partMatch"

    StateServer.Client.part_match(user.id)

    <<>>
  end

  defp handle_packet(38, data, user) do
    Logger.warn "#{Color.username(user.username)}!matchChangeSlot: #{inspect data}"

    StateServer.Client.change_slot(user, data[:slot_id])

    <<>>
  end

  defp handle_packet(39, _data, user) do
    Logger.warn "#{Color.username(user.username)}!matchReady"

    StateServer.Client.match_ready(user)

    <<>>
  end

  defp handle_packet(40, data, user) do
    Logger.warn "#{Color.username(user.username)}!lockMatchSlot: slot #{data[:slot_id]}"

    StateServer.Client.lock_match_slot(user, data[:slot_id])

    <<>>
  end

  defp handle_packet(41, data, user) do
    Logger.warn "#{Color.username(user.username)}!matchChangeSettings: #{data[:match_id]}"

    StateServer.Client.change_match_settings(user, data)

    <<>>
  end

  defp handle_packet(44, data, user) do
    Logger.warn "#{Color.username(user.username)}!matchStart: #{inspect(data, limit: :infinity)}"

    StateServer.Client.match_start(user)

    <<>>
  end

  defp handle_packet(47, data, user) do
    Logger.debug "#{Color.username(user.username)}!matchScoreUpdate: #{inspect data}"

    StateServer.Client.match_frames(user, data[:data])

    <<>>
  end

  defp handle_packet(49, _data, user) do
    Logger.warn "#{Color.username(user.username)}!matchComplete"

    StateServer.Client.match_complete(user)

    <<>>
  end

  defp handle_packet(51, data, user) do
    Logger.warn "#{Color.username(user.username)}!matchChangeMods: #{inspect(data, limit: :infinity)}"

    StateServer.Client.change_mods(user, data[:mods])

    <<>>
  end

  defp handle_packet(52, _data, user) do
    Logger.warn "#{Color.username(user.username)}!matchLoadComplete"

    StateServer.Client.match_load_complete(user)

    <<>>
  end

  defp handle_packet(54, _data, user) do
    Logger.warn "#{Color.username(user.username)}!matchNoBeatmap"

    StateServer.Client.match_has_beatmap(user, false)

    <<>>
  end

  defp handle_packet(55, _data, user) do
    Logger.warn "#{Color.username(user.username)}!matchNotReady"

    StateServer.Client.match_not_ready(user)

    <<>>
  end

  defp handle_packet(59, _data, user) do
    Logger.warn "#{Color.username(user.username)}!matchHasBeatmap"

    StateServer.Client.match_has_beatmap(user, true)

    <<>>
  end

  defp handle_packet(60, _data, user) do
    Logger.warn "#{Color.username(user.username)}!matchSkipRequest"

    StateServer.Client.match_skip_request(user)

    <<>>
  end

  defp handle_packet(63, data, user) do
    channel_name = data[:channel]
    Logger.warn "#{Color.username(user.username)}!channelJoin: #{channel_name}"

    StateServer.Client.join_channel(user.id, channel_name)

    Packet.channel_join_success(channel_name)
  end

  defp handle_packet(68, data, user) do
    Logger.warn "#{Color.username(user.username)}!beatmapInfoRequest: #{inspect data}"
    <<>>
  end

  defp handle_packet(70, data, user) do
    Logger.warn "#{Color.username(user.username)}!matchTransferHost: #{inspect data}"

    StateServer.Client.match_transfer_host(user, data[:slot_id])

    <<>>
  end

  defp handle_packet(73, data, user) do
    friend_id = data[:friend_id]
    Logger.warn "#{Color.username(user.username)}!friendAdd: #{friend_id}"

    user_id = user.id
    changeset = Friendship.changeset(%Friendship{}, %{
      requester_id: user_id,
      receiver_id: friend_id,
    })
    case Repo.insert changeset do
      {:ok, friendship} ->
        friendship = Repo.preload friendship, :receiver
        Logger.warn "#{Color.username(user.username)} has added #{friendship.receiver.username}!"
      {:error, changeset} ->
        Logger.warn "#{Color.username(user.username)} failed to add #{friend_id}"
        Logger.warn inspect changeset.errors
    end

    <<>>
  end

  defp handle_packet(74, data, user) do

    user_id = user.id
    friend_id = data[:friend_id]

    query = from f in Friendship,
      where: f.requester_id == ^user_id
        and f.receiver_id == ^friend_id,
        preload: [:receiver]

    case Repo.one query do
      nil ->
        Logger.error "#{Color.username(user.username)} tried to remove #{friend_id}, who they're not already friends with!"
      friendship ->
        case Repo.delete friendship do
          {:ok, _} ->
            Logger.warn "#{Color.username(user.username)} has removed #{friendship.receiver.username}!"
          {:error, changeset} ->
            Logger.warn "#{Color.username(user.username)} failed to remove #{friendship.receiver.username}"
            Logger.warn inspect changeset.errors
        end
    end

    <<>>
  end

  # client_channelPart
  defp handle_packet(78, data, user) do
    channel_name = data[:channel]
    Logger.warn "#{Color.username(user.username)}!channelPart - #{channel_name}"

    # For some reason, osu! client sends a channelPart when a private message
    # channel is closed
    if String.starts_with?(channel_name, "#") do
      StateServer.Client.part_channel(user.id, channel_name)
    end

    <<>>
  end

  defp handle_packet(79, _data, _user) do
    # client_receiveUpdates

    <<>>
  end

  defp handle_packet(85, data, user) do
    # userStatsRequest

    # No idea why the integer is coming out unsigned, this is -1 in signed 32 bit
    user_id = data[:user_id]
    unless user_id == 4294967295 do
      case Repo.get User, user_id do
        nil ->
          Logger.warn "#{Color.username(user.username)}!userStatsRequest - user with id #{user_id} does not exist"
          <<>>
        target_user ->
          Logger.info "#{Color.username(user.username)}!userStatsRequest - #{target_user.username}"
          Packet.user_stats(target_user)
      end
    else
      <<>>
    end
  end

  defp handle_packet(87, data, user) do
    Logger.warn "#{Color.username(user.username)}!invite - #{inspect data}"

    StateServer.Client.match_invite(user, data[:user_id])

    <<>>
  end

  defp handle_packet(90, data, user) do
    Logger.warn "#{Color.username(user.username)}!matchChangePassword - match_id=#{data[:match_id]} match_password=\"#{data[:match_password]}\""

    StateServer.Client.match_change_password(user, data)

    <<>>
  end

  defp handle_packet(97, data, user) do
    Logger.warn "#{Color.username(user.username)}!userPresenceRequest - #{inspect data}"

    <<>>
  end

  defp handle_packet(packet_id, data, user) do
    Logger.warn "Unhandled packet #{packet_id} from #{Color.username(user.username)}: #{inspect data}"

    <<>>
  end

  defp prepare_conn(conn, cho_token \\ "") do
    conn
    |> Plug.Conn.put_resp_header("cho-token", cho_token)
    |> Plug.Conn.put_resp_header("cho-protocol", "19")
    |> Plug.Conn.put_resp_header("Keep-Alive", "timeout=5, max=100")
    |> Plug.Conn.put_resp_header("Connection", "keep-alive")
    |> Plug.Conn.put_resp_header("Content-Type", "text/html; charset=UTF-8")
    |> Plug.Conn.put_resp_header("Vary", "Accept-Encoding")
  end

  defp login_packets(user) do
    # TODO: Get these from the state server
    channels = ["#osu", "#announce"]
    other_channels = []

    action = StateServer.Client.action(user.id)
    user_panel_packet = Packet.user_panel(user, action)
    user_stats_packet = Packet.user_stats(user, action)

    online_users = [TruckLord.user_id | StateServer.Client.user_ids()]
    |> Enum.map(fn(user_id) ->
      Repo.get! User, user_id
    end)

    # Logger.warn "online users: #{inspect online_users}"

    Packet.silence_end_time(0)
    <> Packet.user_id(user.id)
    <> Packet.protocol_version
    <> Packet.user_supporter_gmt(true, false)
    <> user_panel_packet
    <> user_stats_packet
    <> Packet.channel_info_end
    <> Enum.reduce(channels, <<>>, &(&2 <> Packet.channel_join_success(&1)))
    <> Enum.reduce(channels, <<>>, &(&2 <> Packet.channel_info(&1)))
    <> Enum.reduce(other_channels, <<>>, &(&2 <> Packet.channel_info(&1)))
    # TODO: Dynamically add channel info
    <> Packet.friends_list(user)
    # TODO: Menu icon
    <> Enum.reduce(online_users, <<>>, &(&2 <> Packet.user_panel(&1)))
    <> Enum.reduce(online_users, <<>>, &(&2 <> Packet.user_stats(&1)))
    <> Packet.online_users
    <> Packet.notification("Server IP will be changing soon! You can find the new one in the Discord, in the #general topic, or in #changelog.")
  end
end
