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

  def show(conn, %{"id" => id}) do
    case Client.action(id) do
      action when is_list(action) ->
        conn
        |> json(%{
          id: id,
          action: action |> Enum.into(%{}),
        })
      _ ->
        conn
        |> put_status(404)
        |> json(%{"ok" => false})
    end
  end
end

