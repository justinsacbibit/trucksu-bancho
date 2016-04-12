defmodule StateServerTest do
  use ExUnit.Case, async: true
  alias Game.StateServer

  setup context do
    {:ok, server} = StateServer.start_link(context.test)
    {:ok, server: server}
  end

  test "new server has an empty map of users", %{server: server} do
    users = StateServer.Client.users(server)

    assert users == %{}
  end

  test "new server has a map of channels with the default channels", %{server: server} do
    channels = StateServer.Client.channels(server)

    osu_channel_users = channels["#osu"]
    assert osu_channel_users == MapSet.new()

    announce_channel_users = channels["#announce"]
    assert announce_channel_users == MapSet.new()
  end

  test "adding a user updates the users map", %{server: server} do
    user_id = 1
    username = "Truck Driver"
    token = "abc123"
    user = %{id: user_id, username: username}

    StateServer.Client.add_user(server, user, token)

    users = StateServer.Client.users(server)

    assert Map.has_key?(users, user_id)

    user_data = Map.get(users, user_id)
    assert user_data.username == username
    assert user_data.token == token
    assert MapSet.member?(user_data.channels, "#osu")
    assert MapSet.member?(user_data.channels, "#announce")
  end

  test "adding a user updates the channels map", %{server: server} do
    user_id = 1
    username = "Truck Driver"
    token = "abc123"
    user = %{id: user_id, username: username}

    StateServer.Client.add_user(server, user, token)

    channels = StateServer.Client.channels(server)

    assert MapSet.member?(channels["#osu"], user_id)
    assert MapSet.member?(channels["#announce"], user_id)
  end

  test "enqueue and dequeue a packet for a user", %{server: server} do
    user_id = 1
    username = "Truck Driver"
    token = "abc123"
    user = %{id: user_id, username: username}

    StateServer.Client.add_user(server, user, token)

    StateServer.Client.enqueue(server, user_id, <<1>>)

    packet_queue = StateServer.Client.dequeue(server, user_id)

    assert length(packet_queue) == 1

    [packet] = packet_queue
    assert packet == <<1>>

    packet_queue = StateServer.Client.dequeue(server, user_id)

    assert length(packet_queue) == 0
  end

  test "enqueue and dequeue a packet for all users", %{server: server} do
    user_id = 1
    username = "Truck Driver"
    token = "abc123"
    user = %{id: user_id, username: username}

    StateServer.Client.add_user(server, user, token)

    StateServer.Client.enqueue_all(server, <<1>>)

    packet_queue = StateServer.Client.dequeue(server, user_id)

    assert length(packet_queue) == 1

    [packet] = packet_queue
    assert packet == <<1>>

    packet_queue = StateServer.Client.dequeue(server, user_id)

    assert length(packet_queue) == 0
  end

  test "change and get action for a user", %{server: server} do
    user_id = 1
    username = "Truck Driver"
    token = "abc123"
    user = %{id: user_id, username: username}

    StateServer.Client.add_user(server, user, token)

    action = [action_id: 0, action_text: "", action_md5: "", action_mods: 0]
    StateServer.Client.change_action(server, user_id, action)

    assert StateServer.Client.action(server, user_id) == action
  end
end
