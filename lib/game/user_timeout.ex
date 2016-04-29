defmodule Game.UserTimeout do
  require Logger
  use Timex
  alias Game.StateServer
  alias Game.Utils.Color

  def start_link do
    Task.start_link(fn -> check_timeout() end)
  end

  @timeout 100 * 1000
  @expire 100

  defp check_timeout() do
    :timer.sleep @timeout

    user_ids = StateServer.Client.user_ids()

    Enum.each user_ids, fn(user_id) ->
      time = StateServer.Client.retrieve_last_request_time(user_id)

      if Time.diff(Time.now, time, :seconds) > @expire do
        username = StateServer.Client.username(user_id)
        Logger.warn "Disconnecting #{Color.username(username)}"
        StateServer.Client.remove_user(user_id)
      end
    end

    check_timeout()
  end
end

