defmodule Game.GameController do
  use Game.Web, :controller
  require Logger
  alias Game.{Packet, StateServer}
  alias Trucksu.{Repo, Session, User}

  def index(conn, _params) do
    osu_token = Plug.Conn.get_req_header(conn, "osu-token")
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    handle_request(conn, body, osu_token)
  end

  def send_packet(packet_id, data, user) do
    handle_packet(packet_id, data, user)
  end

  defp handle_request(conn, body, []) do
    Logger.debug body
    [username, hashed_password | _] = String.split(body, "\n")

    Logger.warn "Handling login for #{username}"

    case Session.authenticate(username, hashed_password, true) do
      {:ok, user} ->
        {:ok, jwt, _full_claims} = user |> Guardian.encode_and_sign(:token)

        StateServer.Client.add_user(user, jwt)

        render prepare_conn(conn, jwt), "response.raw", data: login_packets(user)
      :error ->
        Logger.debug "Login failed for #{username}"
        render prepare_conn(conn), "response.raw", data: Packet.login_failed
    end
  end

  defp handle_request(conn, stacked_packets, [osu_token]) do
    data = case Guardian.decode_and_verify(osu_token) do
      {:ok, claims} ->

        # TODO: Consider preventing SQL queries when it is a pong packet
        #       and the packet queue is empty
        {:ok, user} = Guardian.serializer.from_token(claims["sub"])

        # TODO: Return an error if the user is somehow not in the state

        data = Packet.Decoder.decode_packets(stacked_packets)
        |> Enum.reduce(<<>>, fn({packet_id, data}, acc) ->
          acc <> handle_packet(packet_id, data, user)
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
    Logger.debug "Handling changeAction: data: #{inspect data}, user id: #{user.id}"
    # TODO: Possibly enqueue user panel as well..

    StateServer.Client.change_action(user.id, data)

    packet = Packet.user_stats(user, data)
    StateServer.Client.enqueue_all(packet)
    <<>>
  end

  defp handle_packet(1, data, user) do
    channel_name = data[:to]
    Logger.warn "handling sendPublicMessage for channel #{channel_name}"
    packet = Packet.send_message(user.username, data[:message], channel_name, user.id)
    ChannelServer.whereis(channel_name)
    |> GenServer.cast({:send, packet, user.id})

    <<>>
  end

  defp handle_packet(2, data, user) do
    packet = Packet.logout(user.id)
    UserServer.Supervisor.enqueue_all(packet)

    ChannelServer.Supervisor.cast_all({:part, user.id})

    <<>>
  end

  defp handle_packet(3, data, user) do
    Logger.debug "Unhandled requestStatusUpdate"
    <<>>
  end

  defp handle_packet(4, _data, _user) do
    <<>>
  end

  defp handle_packet(25, data, user) do
    Logger.warn "Handling sendPrivateMessage from #{user.username}, data: #{inspect data}"

    to = data[:to]
    message = data[:message]

    packet = Packet.send_message(user.username, message, to, user.id)

    pid = Supervisor.which_children(UserServer.Supervisor)
    |> Enum.reduce_while(nil, fn({_, pid, _, _}, acc) ->
      case GenServer.call(pid, :username) do
        ^to -> {:halt, pid}
        _ -> {:cont, acc}
      end
    end)

    if is_nil(pid) do
      Logger.error "Unable to find UserServer for #{to} when sending private message"
    else
      Logger.warn "Sending private message \"#{message}\" from #{user.username} to #{to}"
      GenServer.cast(pid, {:enqueue, packet})
    end

    <<>>
  end

  defp handle_packet(63, data, user) do
    channel_name = data[:channel]
    Logger.warn "Handling channel join for channel #{channel_name}"

    ChannelServer.whereis(channel_name)
    |> GenServer.cast({:join, user.id})

    Packet.channel_join_success(channel_name)
  end

  defp handle_packet(68, data, user) do
    Logger.warn "Unhandled beatmapInfoRequest"
    Logger.warn inspect data
    <<>>
  end

  # client_channelPart
  defp handle_packet(78, [channel: channel_name], user) do
    Logger.warn "Handling channel part for channel #{channel_name}"

    ChannelServer.whereis(channel_name)
    |> GenServer.cast({:part, user.id})

    <<>>
  end

  defp handle_packet(85, data, user) do
    # userStatsRequest

    # No idea why the integer is coming out unsigned, this is -1 in signed 32 bit
    unless data[:user_id] == 4294967295 do
      case Repo.get User, data[:user_id] do
        nil ->
          <<>>
        user ->
          Packet.user_stats(user)
      end

    end
  end

  defp handle_packet(packet_id, data, user) do
    Logger.warn "Unhandled packet #{packet_id}"
    Logger.warn inspect data
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
    channels = ["#osu", "#announce"]

    Enum.each channels, fn channel_name ->
      ChannelServer.whereis(channel_name)
      |> GenServer.cast({:join, user.id})
    end

    user_panel_packet = Packet.user_panel(user)
    user_stats_packet = Packet.user_stats(user)

    UserServer.Supervisor.enqueue_all(user_panel_packet)
    UserServer.Supervisor.enqueue_all(user_stats_packet)

    online_users = Supervisor.which_children(UserServer.Supervisor)
    |> Enum.map(fn({user_id, _pid, _, _}) ->
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
    # TODO: Dynamically add channel info
    <> Packet.friends_list(user)
    # TODO: Menu icon
    <> Packet.notification("Welcome to the UW Meme Server!")
    <> Enum.reduce(online_users, <<>>, &(&2 <> Packet.user_panel(&1)))
    <> Enum.reduce(online_users, <<>>, &(&2 <> Packet.user_stats(&1)))
    <> Packet.online_users
  end
end
