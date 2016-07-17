defmodule Game.MatchJanitor do
  require Logger
  alias Game.StateServer

  def start_link do
    Task.start_link(&work/0)
  end

  @sleep 60 * 1000 # 1 minute

  defp work do
    :timer.sleep @sleep

    StateServer.Client.dispose_empty_matches()

    work()
  end
end
