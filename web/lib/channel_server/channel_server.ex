defmodule Game.ChannelServer do
  use GenServer
  alias Game.{Packet, UserServer}

  def start_link(channel_name) do
    state = %{
      channel_name: channel_name,
      users: MapSet.new,
    }
    name = server_name(channel_name)
    GenServer.start_link(__MODULE__, state, name: name)
  end

  def whereis(channel_name) do
    GenServer.whereis(server_name(channel_name))
  end

  def server_name(channel_name) do
    String.to_atom("channel_server#{channel_name}")
  end

  def handle_cast({:join, user_id}, %{users: users} = state) do
    users = MapSet.put(users, user_id)
    state = %{state | users: users}

    {:noreply, state}
  end

  def handle_cast({:part, user_id}, %{users: users} = state) do
    users = MapSet.delete(users, user_id)
    state = %{state | users: users}

    {:noreply, state}
  end

  def handle_cast({:send, packet, from}, %{users: users} = state) do
    Enum.each users, fn user_id ->
      if user_id != from do
        pid = UserServer.whereis(user_id)
        if pid do
          GenServer.cast(pid, {:enqueue, packet})
        end
      end
    end

    {:noreply, state}
  end

  def handle_call(:users, _from, %{users: users} = state) do
    {:reply, users, state}
  end
end
