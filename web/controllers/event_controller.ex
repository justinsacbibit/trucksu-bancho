defmodule Game.EventController do
  use Game.Web, :controller
  require Logger
  alias Game.{Packet, StateServer}
  alias Trucksu.{Repo, User}

  def index(conn, %{"cookie" => cookie, "event_type" => event_type} = params) do
    server_cookie = Application.get_env(:game, :server_cookie)
    ^server_cookie = cookie

    case event_type do
      "pp" ->
        %{
          "pp" => pp,
          "username" => username,
          "beatmap_id" => beatmap_id,
          "version" => version,
          "artist" => artist,
          "title" => title,
          "creator" => creator,
        } = params

        bot = Repo.get User, 1 # TODO: Remove hardcoding

        # TODO: Use beatmap_id
        message = "You just achieved #{pp}pp on #{artist} - #{title} [#{version}]!"
        packet = Packet.send_message(bot.username, message, username, bot.id)
        Logger.warn "Queuing pp message for #{username}: #{message}"
        StateServer.Client.enqueue_for_username(username, packet)
      _ ->
        Logger.warn "Unhandled event_type: #{event_type}"
    end

    render conn, "response.raw", data: <<>>
  end
end

