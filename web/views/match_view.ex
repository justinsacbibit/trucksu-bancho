defmodule Game.MatchView do
  use Game.Web, :view

  def render("show.json", %{match: match}) do
    %{
      match_id: match[:match_id],
      in_progress: match[:in_progress],
      mods: match[:mods],
      match_name: match[:match_name],
      beatmap_id: match[:beatmap_id],
      beatmap_name: match[:beatmap_name],
      host_user_id: match[:host_user_id],
      game_mode: match[:game_mode],
      match_scoring_type: match[:match_scoring_type],
      match_team_type: match[:match_team_type],
      match_mod_mode: match[:match_mod_mode],
      slots: for slot <- match[:slots] do
        %{
          slot_id: slot[:slot_id],
          status: slot[:status],
          team: slot[:team],
          user_id: slot[:user_id],
          mods: slot[:mods],
          loaded: slot[:loaded],
          skip: slot[:skip],
          complete: slot[:complete],
        }
      end,
    }
  end

  def render("index.json", %{matches: matches}) do
    render_many(matches, __MODULE__, "show.json")
  end
end

