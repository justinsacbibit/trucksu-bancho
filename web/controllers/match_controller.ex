defmodule Game.MatchController do
  use Game.Web, :controller
  alias Game.StateServer.Client

  # TODO: Check cookie

  def index(conn, _params) do
    all_match_data = Client.all_match_data()

    render(conn, "index.json", matches: all_match_data)
  end
end

