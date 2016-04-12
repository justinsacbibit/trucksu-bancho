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
  def start_link() do
    state = %{
      users: %{},

      # Maps default_channels into new channel states
      channels: Enum.map(@default_channels, fn(channel) ->
        {channel, MapSet.new()}
      end)
      |> Enum.into(%{}),
    }
    GenServer.start_link(__MODULE__, state, name: @name)
  end

  ## Server callbacks

  # TODO: Tests, possibly make synchronous
  def handle_cast({:add_user, user, token}, %{users: users, channels: channels} = state) do

    users = Map.put(users, user.id, %{
      username: user.username,
      token: token,
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

  def handle_call(:users, _from, %{users: users} = state) do

  end
end
