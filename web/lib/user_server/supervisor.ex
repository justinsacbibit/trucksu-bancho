defmodule Game.UserServer.Supervisor do
  use Supervisor
  alias Game.UserServer

  @name Game.UserServer.Supervisor

  def start_link() do
    Supervisor.start_link(__MODULE__, :ok, name: @name)
  end

  def start_user_server(args) do
    Supervisor.start_child(
      @name,
      worker(UserServer, [args], id: args[:user_id])
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
    children = []

    supervise(children, strategy: :one_for_one)
  end

  def enqueue_all(packet, opts \\ []) do
    Supervisor.which_children(__MODULE__)
    |> Enum.each(fn({_, pid, _, _}) ->
      GenServer.cast(pid, {:enqueue, packet, opts})
    end)
  end
end

