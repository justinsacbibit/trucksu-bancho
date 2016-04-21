defmodule Game.StateServer do
  @moduledoc """
  Contains the global state for the Bancho server.
  """
  require Logger

  use GenServer

  alias Game.Packet

  @name Game.StateServer
  @default_channels ["#osu", "#announce"]
  @other_channels []

  @doc """
  Starts the state server.
  """
  def start_link(name \\ @name) do
    GenServer.start_link(__MODULE__, initial_state(), name: name)
  end

  ## Server callbacks

  # TODO: Possibly make synchronous
  def handle_cast({:add_user, user, token}, %{users: users, channels: channels} = state) do

    already_in_state = Map.has_key?(users, user.id)
    if already_in_state do
      channels = remove_user_from_channels(user.id, channels)
    end

    users = Map.put(users, user.id, %{
      username: user.username,
      token: token,
      packet_queue: [],
      action: default_user_action(),
    })

    # Add the user into the default channels
    channels = Enum.reduce(@default_channels, channels, fn(channel, channels) ->
      Map.update(channels, channel, MapSet.new(), fn(users) ->
        MapSet.put(users, user.id)
      end)
    end)

    state = %{state | users: users, channels: channels}

    {:noreply, state}
  end

  def handle_cast({:join_channel, user_id, channel}, %{channels: channels} = state) do

    channel_users = Map.get(channels, channel)
    |> MapSet.put(user_id)

    channels = Map.put(channels, channel, channel_users)

    {:noreply, %{state | channels: channels}}
  end

  def handle_cast({:part_channel, user_id, channel}, %{channels: channels} = state) do
    channel_users = Map.get(channels, channel)
    |> MapSet.delete(user_id)

    channels = Map.put(channels, channel, channel_users)

    {:noreply, %{state | channels: channels}}
  end

  def handle_cast({:create_channel, channel}, %{channels: channels} = state) do
    channels = Map.put(channels, channel, MapSet.new())

    {:noreply, %{state | channels: channels}}
  end

  def handle_cast({:send_public_message, channel, packet, from_user_id}, %{users: users, channels: channels} = state) do
    channel_users = Map.get(channels, channel)
    # TODO: This will crash the server is channel_users is nil
    users = Enum.reduce(channel_users, users, fn(channel_user, users) ->
      if channel_user != from_user_id do
        enqueue_for_user(users, channel_user, packet)
      else
        users
      end
    end)

    {:noreply, %{state | users: users}}
  end

  def handle_cast({:enqueue, user_id, packet}, %{users: users} = state) do
    users = enqueue_for_user(users, user_id, packet)

    {:noreply, %{state | users: users}}
  end

  def handle_cast({:enqueue_for_username, username, packet}, %{users: users} = state) do
    # TODO: Improve time complexity by adding another Map to the state which
    # maps usernames to user ids

    result = Enum.find(users, fn({_, %{username: curr_username}}) ->
      curr_username == username
    end)

    case result do
      nil ->
        Logger.warn "Attempted to enqueue a packet for username #{username}, who is not in the state."

      {user_id, _} ->
        users = enqueue_for_user(users, user_id, packet)

    end

    {:noreply, %{state | users: users}}
  end

  def handle_cast({:enqueue_all, packet}, %{users: users} = state) do
    users = enqueue_all(users, packet)

    {:noreply, %{state | users: users}}
  end

  def handle_cast({:change_action, user_id, action}, %{users: users} = state) do
    user = Map.get(users, user_id)
    user = %{user | action: action}
    users = Map.put(users, user_id, user)
    {:noreply, %{state | users: users}}
  end

  def handle_cast({:remove_user, user_id}, %{users: users, channels: channels} = state) do
    logout_packet = Packet.logout(user_id)

    users = Map.delete(users, user_id)
    |> enqueue_all(logout_packet)

    channels = remove_user_from_channels(user_id, channels)

    {:noreply, %{state | users: users, channels: channels}}
  end

  def handle_cast(:reset, _state) do
    {:noreply, initial_state()}
  end

  def handle_call({:dequeue, user_id}, _from, %{users: users} = state) do
    {packet_queue, users} = if not Map.has_key?(users, user_id) do
      packet_queue = [Packet.server_restart(0)]

      {packet_queue, users}
    else
      user = users[user_id]
      packet_queue = user.packet_queue
      user = %{user | packet_queue: []}

      users = Map.put(users, user_id, user)

      {packet_queue, users}
    end

    {:reply, packet_queue, %{state | users: users}}
  end

  def handle_call(:channels, _from, %{channels: channels} = state) do
    {:reply, channels, state}
  end

  def handle_call(:users, _from, %{users: users} = state) do
    {:reply, users, state}
  end

  def handle_call({:action, user_id}, _from, %{users: users} = state) do
    action = case Map.get(users, user_id) do
      nil ->
        # a bit hacky
        default_user_action()
      user ->
        user.action
    end

    {:reply, action, state}
  end

  defp enqueue_all(users, packet) do
    users = Enum.map(users, fn({user_id, user}) ->
      packet_queue = user.packet_queue ++ [packet]
      {user_id, %{user | packet_queue: packet_queue}}
    end)
    |> Enum.into(%{})

    users
  end

  defp enqueue_for_user(users, user_id, packet) do
    user = users[user_id]

    if is_nil(user) do
      Logger.warn "Attempted to enqueue a packet for user id #{user_id}, who is not in the state."
    else
      packet_queue = user.packet_queue ++ [packet]
      user = %{user | packet_queue: packet_queue}

      users = Map.put(users, user_id, user)
    end

    users
  end

  defp remove_user_from_channels(user_id, channels) do
    map_channels(channels, fn(users) ->
      MapSet.delete(users, user_id)
    end)
  end

  defp map_channels(channels, func) do
    Enum.map(channels, fn({channel, users}) ->
      {channel, func.(users)}
    end)
    |> Enum.into(%{})
  end

  defp default_user_action() do
    [
      action_id: 0,
      action_text: "",
      action_md5: "",
      action_mods: 0,
      game_mode: 0,
    ]
  end

  defp initial_state() do
    %{
      users: %{},

      # Maps default_channels into new channel states
      channels: Enum.map(@default_channels ++ @other_channels, fn(channel) ->
        {channel, MapSet.new()}
      end)
      |> Enum.into(%{}),
    }
  end
end
