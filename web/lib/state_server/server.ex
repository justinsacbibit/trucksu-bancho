defmodule Game.StateServer do
  @moduledoc """
  Contains the global state for the Bancho server.
  """

  use GenServer

  @name Game.StateServer
  @default_channels ["#osu", "#announce"]

  @doc """
  Starts the state server.
  """
  def start_link(name \\ @name) do
    state = %{
      users: %{},

      # Maps default_channels into new channel states
      channels: Enum.map(@default_channels, fn(channel) ->
        {channel, MapSet.new()}
      end)
      |> Enum.into(%{}),
    }
    GenServer.start_link(__MODULE__, state, name: name)
  end

  ## Server callbacks

  # TODO: Possibly make synchronous
  def handle_cast({:add_user, user, token}, %{users: users, channels: channels} = state) do

    users = Map.put(users, user.id, %{
      username: user.username,
      token: token,
      channels: Enum.into(@default_channels, MapSet.new()),
      packet_queue: [],
      action: [
        action_id: 0,
        action_text: "",
        action_md5: "",
        action_mods: 0,
        game_mode: 0,
      ],
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

  def handle_cast({:enqueue, user_id, packet}, %{users: users} = state) do
    user = users[user_id]
    packet_queue = user.packet_queue ++ [packet]
    user = %{user | packet_queue: packet_queue}

    users = Map.put(users, user_id, user)

    {:noreply, %{state | users: users}}
  end

  def handle_cast({:enqueue_all, packet}, %{users: users} = state) do
    users = Enum.map(users, fn({user_id, user}) ->
      packet_queue = user.packet_queue ++ [packet]
      {user_id, %{user | packet_queue: packet_queue}}
    end)
    |> Enum.into(%{})

    {:noreply, %{state | users: users}}
  end

  def handle_cast({:change_action, user_id, action}, %{users: users} = state) do
    user = Map.get(users, user_id)
    user = %{user | action: action}
    users = Map.put(users, user_id, user)
    {:noreply, %{state | users: users}}
  end

  def handle_call({:dequeue, user_id}, _from, %{users: users} = state) do
    user = users[user_id]
    packet_queue = user.packet_queue
    user = %{user | packet_queue: []}

    users = Map.put(users, user_id, user)

    {:reply, packet_queue, %{state | users: users}}
  end

  def handle_call(:channels, _from, %{channels: channels} = state) do
    {:reply, channels, state}
  end

  def handle_call(:users, _from, %{users: users} = state) do
    {:reply, users, state}
  end

  def handle_call({:action, user_id}, _from, %{users: users} = state) do
    action = Map.get(users, user_id).action

    {:reply, action, state}
  end
end
