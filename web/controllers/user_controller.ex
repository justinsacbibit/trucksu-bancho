defmodule Game.UserController do
  use Game.Web, :controller
  alias Game.StateServer.Client

  # TODO: Check cookie

  def index(conn, params) do
    users = for user_id <- Client.user_ids(),
      action = Client.action(user_id),
      is_list(action) do
        %{
          id: user_id,
          action: action |> Enum.into(%{}),
        }
    end

    conn
    |> json(users)
  end

  def show(conn, params) do
    # TODO
    conn
  end
end

