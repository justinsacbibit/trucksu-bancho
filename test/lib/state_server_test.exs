defmodule StateServerTest do
  use ExUnit.Case, async: true
  alias Game.StateServer

  setup context do
    {:ok, server} = StateServer.start_link(context.test)
    {:ok, server: server}
  end

  test "first parameter is the default server" do
    StateServer.Client.users()
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

  test "removing a user", %{server: server} do
    user_id = 1
    username = "Truck Driver"
    token = "abc123"
    user = %{id: user_id, username: username}

    StateServer.Client.add_user(server, user, token)
    StateServer.Client.remove_user(server, user_id)

    users = StateServer.Client.users(server)
    channels = StateServer.Client.channels(server)

    assert not Map.has_key?(users, user_id)
    assert not MapSet.member?(channels["#osu"], user_id)
    assert not MapSet.member?(channels["#announce"], user_id)
  end

  test "when creating a channel, it should be empty initially", %{server: server} do
    user_id = 1
    username = "Truck Driver"
    token = "abc123"
    user = %{id: user_id, username: username}

    channel = "#random"

    StateServer.Client.add_user(server, user, token)
    StateServer.Client.create_channel(server, channel)

    channels = StateServer.Client.channels(server)

    assert MapSet.size(channels[channel]) == 0
  end

  test "joining a channel", %{server: server} do
    user_id = 1
    username = "Truck Driver"
    token = "abc123"
    user = %{id: user_id, username: username}

    channel = "#random"

    StateServer.Client.add_user(server, user, token)
    StateServer.Client.create_channel(server, channel)
    StateServer.Client.join_channel(server, user_id, channel)

    channel_users = StateServer.Client.channels(server)[channel]

    assert MapSet.size(channel_users) == 1
    assert MapSet.member?(channel_users, user_id)
  end

  test "leaving a channel", %{server: server} do
    user_id = 1
    username = "Truck Driver"
    token = "abc123"
    user = %{id: user_id, username: username}

    channel = "#random"

    StateServer.Client.add_user(server, user, token)
    StateServer.Client.create_channel(server, channel)
    StateServer.Client.join_channel(server, user_id, channel)
    StateServer.Client.part_channel(server, user_id, channel)

    channel_users = StateServer.Client.channels(server)[channel]

    assert MapSet.size(channel_users) == 0
  end

  test "creating a channel", %{server: server} do
    channel = "#random"
    StateServer.Client.create_channel(server, channel)

    assert Map.has_key?(StateServer.Client.channels(server), channel)
  end

  test "sending a public message", %{server: server} do
    channel = "#osu"

    user_id1 = 1
    username1 = "Truck Driver"
    token1 = "abc123"
    user1 = %{id: user_id1, username: username1}

    user_id2 = 2
    username2 = "Joseph"
    token2 = "abc123"
    user2 = %{id: user_id2, username: username2}

    StateServer.Client.add_user(server, user1, token1)
    StateServer.Client.add_user(server, user2, token2)

    packet = <<1, 2, 4>>
    StateServer.Client.send_public_message(server, channel, packet, user_id1)

    users = StateServer.Client.users(server)

    assert length(users[user_id1].packet_queue) == 0
    assert users[user_id2].packet_queue == [packet]
  end

  test "adding a user that is already in the state removes them from channels", %{server: server} do
    user_id = 1
    username = "Truck Driver"
    token = "abc123"
    user = %{id: user_id, username: username}

    channel = "#random"

    StateServer.Client.add_user(server, user, token)
    StateServer.Client.create_channel(server, channel)
    StateServer.Client.join_channel(server, user_id, channel)

    channel_users = StateServer.Client.channels(server)[channel]
    assert MapSet.member?(channel_users, user_id)

    StateServer.Client.add_user(server, user, token)

    channel_users = StateServer.Client.channels(server)[channel]
    assert MapSet.size(channel_users) == 0
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

  test "enqueue a packet for a non-existent user id", %{server: server} do
    user_id = 1
    StateServer.Client.enqueue(server, user_id, <<1>>)
  end

  test "enqueue and dequeue a packet for a user using their username", %{server: server} do
    user_id = 1
    username = "Truck Driver"
    token = "abc123"
    user = %{id: user_id, username: username}

    StateServer.Client.add_user(server, user, token)

    StateServer.Client.enqueue_for_username(server, username, <<1>>)

    packet_queue = StateServer.Client.dequeue(server, user_id)

    assert length(packet_queue) == 1

    [packet] = packet_queue
    assert packet == <<1>>

    packet_queue = StateServer.Client.dequeue(server, user_id)

    assert length(packet_queue) == 0
  end

  test "enqueue a packet for a non-existent username", %{server: server} do
    username = "Truck Driver"
    StateServer.Client.enqueue_for_username(server, username, <<1>>)
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
