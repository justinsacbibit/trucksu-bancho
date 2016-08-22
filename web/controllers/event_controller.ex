defmodule Game.EventController do
  use Game.Web, :controller
  require Logger
  alias Game.{
    Packet,
    StateServer,
    TruckLord,
    Links,
  }
  alias Trucksu.{Repo, User}

  @server_cookie Application.get_env(:game, :server_cookie)
  @website_url Application.get_env(:game, :website_url)

  # Event types
  @event_type_pp "pp"

  def index(conn, %{"cookie" => @server_cookie} = params) do
    handle_event(params)

    conn
    |> json(%{"ok" => true})
  end

  defp handle_event(%{"event_type" => event_type} = params) do
    case event_type do
      @event_type_pp ->
        %{
          "pp" => pp,
          "user_id" => user_id,
          "username" => username,
          "beatmap_id" => beatmap_id,
          "version" => version,
          "artist" => artist,
          "title" => title,
          "creator" => creator,
          "is_first_place" => is_first_place,
        } = params

        bot = Repo.get! User, TruckLord.user_id

        formatted_song = "[#{Links.Website.beatmap(beatmap_id)} #{artist} - #{title} [#{version}]]"

        message = "You just achieved #{pp}pp on #{formatted_song}!"
        packet = Packet.send_message(bot.username, message, username, bot.id)
        Logger.warn "Queuing pp message for #{username}: #{message}"
        StateServer.Client.enqueue_for_username(username, packet)

        if is_first_place do
          announce_channel_name = "#announce"
          message = "[#{Links.Website.user(user_id)} #{username}] has achieved first place on #{formatted_song}!"

          Logger.warn "Sending first place message to #{announce_channel_name}: #{message}"

          packet = Packet.send_message(bot.username, message, announce_channel_name, bot.id)
          StateServer.Client.send_public_message(announce_channel_name, packet)
        end

      _ ->
        Logger.warn "Unhandled event_type: #{event_type}, params: #{params}"
    end
  end
end

