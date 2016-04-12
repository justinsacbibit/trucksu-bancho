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
end
