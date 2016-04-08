defmodule Game.ChannelServer.Supervisor do
  use Supervisor
  alias Game.ChannelServer

  @name Game.ChannelServer.Supervisor

  def start_link() do
    Supervisor.start_link(__MODULE__, :ok, name: @name)
  end

  def start_channel_server(channel_name) do
    Supervisor.start_child(
      @name,
      worker(ChannelServer, [channel_name], id: channel_name)
    )
  end

  def restart_child(child_id) do
    Supervisor.restart_child(@name, child_id)
  end

  def terminate_child(child_id) do
    Supervisor.terminate_child(@name, child_id)
  end

  def delete_child(pid) do
    Supervisor.delete_child(@name, pid)
  end

  def init(:ok) do
    osu_channel_name = "#osu"
    announce_channel_name = "#announce"
    children = [
      worker(ChannelServer, [osu_channel_name], id: osu_channel_name),
      worker(ChannelServer, [announce_channel_name], id: announce_channel_name),
    ]

    supervise(children, strategy: :one_for_one)
  end

  def cast_all(request) do
    spawn(fn ->
      Supervisor.which_children(__MODULE__)
      |> Enum.each(fn({_, pid, _, _}) ->
        GenServer.cast(pid, request)
      end)
    end)
  end
end

