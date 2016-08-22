defmodule Game.Links.Website do
  @moduledoc """
  Handles creation of links (URLs) to the Trucksu website.
  """

  @website_url Application.get_env(:game, :website_url)

  def beatmap(beatmap_id) do
    "#{@website_url}/b/#{beatmap_id}"
  end

  def user(user_id) do
    "#{@website_url}/u/#{user_id}"
  end
end
