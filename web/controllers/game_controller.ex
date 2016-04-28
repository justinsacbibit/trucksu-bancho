defmodule Game.GameController do
  use Game.Web, :controller
  require Logger
  alias Game.{Packet, StateServer}
  alias Trucksu.{Repo, Session}
  # Models
  alias Trucksu.{Beatmap, User}
  alias Game.Utils

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
    osu_token = conn.assigns[:osu_token]
    case osu_token do
      [] ->
        request_ip = case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
          [request_ip] -> request_ip
          _ -> "0.0.0.0"
        end

        assign(conn, :request_ip, request_ip)
      _ ->
        conn
    end
  end

  defp get_request_location(conn, _) do
    osu_token = conn.assigns[:osu_token]
    case osu_token do
      [] ->
        request_ip = conn.assigns[:request_ip]

        result = if Application.get_env(:game, :get_request_location) do
          result = with {:ok, %HTTPoison.Response{body: body}} <- HTTPoison.get("http://ip-api.com/json/#{request_ip}"),
               {:ok, %{"countryCode" => country_code, "lat" => lat, "lon" => lon}} <- Poison.decode(body),
               do: {:ok, {[lat, lon], Utils.country_id(country_code)}}

          case result do
            {:ok, {[_lat, _lon], _country_code}} ->
              # Verify structure
              result
            _ ->
              nil
          end
        else
          nil
        end

        {location, country_id} = case result do
          {:ok, result} ->
            result
          _ ->
            {[0.0, 0.0], 0}
        end

        conn
        |> assign(:location, location)
        |> assign(:country_id, country_id)

        # TODO: Set the user's country in the database
      _ ->
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
    [username, hashed_password | _] = String.split(body, "\n")

    Logger.warn "Received login request for #{username}"

    case Session.authenticate(username, hashed_password, true) do
      {:ok, user} ->
        {:ok, jwt, _full_claims} = user |> Guardian.encode_and_sign(:token)

        location = conn.assigns[:location]
        country_id = conn.assigns[:country_id]
        StateServer.Client.add_user(user, jwt, {location, country_id})

        render prepare_conn(conn, jwt), "response.raw", data: login_packets(user)
      {:error, reason} ->
        Logger.warn Utils.color("Login failed for #{username}. Reason: #{reason}", IO.ANSI.red)
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
    Logger.warn "changeAction for #{Utils.color(user.username, IO.ANSI.blue)}: #{inspect Enum.map(data, &(elem(&1, 1)))}"

    if data[:action_id] == 2 do
      # The user has started to play a song

      # Example data
      # [action_id: 2, action_text: "Kuba Oms - My Love [Insane]", action_md5: "e9d69824c6d6d584bd055b690f71deaf", action_mods: 65, game_mode: 0]

      beatmap_md5 = data[:action_md5]
      case Repo.get_by(Beatmap, file_md5: beatmap_md5) do
        nil ->
          params = %{
            file_md5: beatmap_md5,
          }
          Repo.insert Beatmap.changeset(%Beatmap{}, params)

        _beatmap ->
          :ok
      end
    end

    StateServer.Client.change_action(user, data)

    <<>>
  end

  defp handle_packet(1, data, user) do
    channel_name = data[:to]
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)} to #{Utils.color(channel_name, IO.ANSI.green)}: #{data[:message]}"

    packet = Packet.send_message(user.username, data[:message], channel_name, user.id)
    case channel_name do
      "#spectator" ->
        StateServer.Client.send_spectator_message(packet, user.id)
      _ ->
        StateServer.Client.send_public_message(channel_name, packet, user.id)
    end

    <<>>
  end

  defp handle_packet(2, _data, user) do
    Logger.warn "Handling logout for #{Utils.color(user.username, IO.ANSI.blue)}"
    StateServer.Client.remove_user(user.id)

    <<>>
  end

  defp handle_packet(3, _data, user) do
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)}!requestStatusUpdate"
    user_panel_packet = Packet.user_panel(user)
    user_stats_packet = Packet.user_stats(user)

    user_panel_packet <> user_stats_packet
  end

  defp handle_packet(4, _data, _user) do
    <<>>
  end

  defp handle_packet(16, data, user) do
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)}!startSpectating"

    host_id = data[:user_id]
    StateServer.Client.spectate(user.id, host_id)

    <<>>
  end

  defp handle_packet(17, _data, user) do
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)}!stopSpectating"

    StateServer.Client.stop_spectating(user.id)

    <<>>
  end

  defp handle_packet(18, data, user) do
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)}!spectateFrames"

    StateServer.Client.spectate_frames(user.id, data[:data])

    <<>>
  end

  defp handle_packet(21, _data, user) do
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)}!cantSpectate"

    StateServer.Client.cant_spectate(user.id)

    <<>>
  end

  defp handle_packet(25, data, user) do
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)} to #{Utils.color(data[:to], IO.ANSI.red)}: #{data[:message]}"

    to_username = data[:to]
    message = data[:message]

    packet = Packet.send_message(user.username, message, to_username, user.id)

    StateServer.Client.enqueue_for_username(to_username, packet)

    # TODO: If to_username is not found in the state, inform the client that the user is offline
    <<>>
  end

  defp handle_packet(29, _data, user) do
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)}!partLobby"

    <<>>
  end

  defp handle_packet(30, _data, user) do
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)}!joinLobby"

    <<>>
  end

  defp handle_packet(31, data, user) do
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)}!createMatch: #{inspect data}"

    <<>>
  end

  defp handle_packet(63, data, user) do
    channel_name = data[:channel]
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)}!channelJoin - #{channel_name}"

    StateServer.Client.join_channel(user.id, channel_name)

    Packet.channel_join_success(channel_name)
  end

  defp handle_packet(68, data, user) do
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)}!beatmapInfoRequest: #{inspect data}"
    <<>>
  end

  # client_channelPart
  defp handle_packet(78, [channel: channel_name], user) do
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)}!channelPart - #{channel_name}"

    # For some reason, osu! client sends a channelPart when a private message
    # channel is closed
    if String.starts_with?(channel_name, "#") do
      StateServer.Client.part_channel(user.id, channel_name)
    end

    <<>>
  end

  defp handle_packet(85, data, _user) do
    # userStatsRequest

    # No idea why the integer is coming out unsigned, this is -1 in signed 32 bit
    unless data[:user_id] == 4294967295 do
      case Repo.get User, data[:user_id] do
        nil ->
          <<>>
        user ->
          Packet.user_stats(user)
      end
    else
      <<>>
    end
  end

  defp handle_packet(97, data, user) do
    Logger.warn "#{Utils.color(user.username, IO.ANSI.blue)}!userPresenceRequest - #{inspect data}"

    <<>>
  end

  defp handle_packet(packet_id, data, user) do
    Logger.warn "Unhandled packet #{packet_id} from #{Utils.color(user.username, IO.ANSI.blue)}: #{inspect data}"
    <<>>
  end

  defp prepare_conn(conn, cho_token \\ "") do
    if cho_token != "" do
      conn = conn
      |> Plug.Conn.put_resp_header("cho-token", cho_token)
    end
    conn
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

    StateServer.Client.enqueue_all(user_panel_packet)
    StateServer.Client.enqueue_all(user_stats_packet)

    online_users = StateServer.Client.user_ids()
    |> Enum.map(fn(user_id) ->
      Repo.get! User, user_id
    end)

    # Logger.warn "online users: #{inspect online_users}"

    Packet.silence_end_time(0)
    <> Packet.user_id(user.id)
    <> Packet.protocol_version
    <> Packet.user_supporter_gmt(false, false)
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
  end
end
