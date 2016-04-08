defmodule Game.UserServer do
  use GenServer

  def start_link(args) do
    name = server_name(args[:user_id])
    state = %{
      user_id: args[:user_id],
      username: args[:username],
      token: args[:token],
      action: %{
        action_id: 0,
        action_text: "",
        action_md5: "",
        action_mods: 0,
        game_mode: 0,
      },
      packet_queue: [],
    }
    GenServer.start_link(__MODULE__, state, name: name)
  end

  def whereis(user_id) do
    GenServer.whereis(server_name(user_id))
  end

  def server_name(user_id) do
    String.to_atom("user_server#{user_id}")
  end

  def handle_call(:dequeue_all, _from, %{packet_queue: packet_queue} = state) do
    state = Map.put(state, :packet_queue, [])
    {:reply, packet_queue, state}
  end

  def handle_call(:action, _from, %{action: action} = state) do
    {:reply, action, state}
  end

  def handle_call(:username, _from, %{username: username} = state) do
    {:reply, username, state}
  end

  @doc """
  Enqueues a packet into the packet queue. The packet will be sent to the client
  on its next request.

  Options:
    `:exclude` - A list of user ids for which the packet should not be enqueued for.
                 If the UserServer's user id is within this list, it ignores the cast.
  """
  def handle_cast({:enqueue, packet}, state), do: handle_cast({:enqueue, packet, []}, state)
  def handle_cast({:enqueue, packet, opts}, %{packet_queue: packet_queue} = state) do
    exclude = opts[:exclude] || []

    exclude_self = Enum.any?(exclude, &(&1 == state.user_id))

    state = if exclude_self do
      state
    else
      Map.put(state, :packet_queue, packet_queue ++ [packet])
    end
    {:noreply, state}
  end

  def handle_cast({:change_action, data}, state) do
    state = Map.put(state, :action, %{
      action_id: data[:action_id],
      action_text: data[:action_text],
      action_md5: data[:action_md5],
      action_mods: data[:action_mods],
      game_mode: data[:game_mode],
    })

    {:noreply, state}
  end
end

