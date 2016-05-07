defmodule Game.TruckLord do
  use GenServer
  require Logger
  use Bitwise
  alias Game.Utils.Color
  alias Game.{Packet, StateServer}

  @name Game.TruckLord
  @user_id 1
  @username "TruckBot"

  def start_link do
    initial_state = %{
    }
    GenServer.start_link(__MODULE__, initial_state, name: @name)
  end

  ## Client

  def receive_message(message, user) do
    GenServer.cast(@name, {:receive_message, message, user})
  end

  @doc """
  Returns a boolean based on whether the bot is online.

  The usefulness of this is debateable.
  """
  def is_online?() do
    GenServer.call(@name, :is_online?)
  end

  @doc """
  Returns the user id of TruckLord.

  The usefulness of this is debateable.
  """
  def user_id() do
    GenServer.call(@name, :user_id)
  end

  @doc """
  Returns the username of TruckLord (which is unfortunately not TruckLord..).

  The usefulness of this is debateable.
  """
  def username() do
    GenServer.call(@name, :username)
  end

  ## Callbacks

  def handle_cast({:receive_message, message, user}, state) do
    Logger.warn "#{Color.username(user.username)} to TrucksuLord received message \"#{message}\""

    case message do
      "!np" ->
        action = StateServer.Client.action(user.id)
        case action do
          nil ->
            Logger.warn "#{Color.username(user.username)} wanted to calculate PP but appears to be offline"
          _ ->

            file_md5 = action[:action_md5]
            mods = action[:action_mods]
            game_mode = action[:game_mode]
            calculate_pp(user, file_md5, mods, game_mode)
        end
      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_call(:is_online?, _from, state) do
    {:reply, true, state}
  end

  def handle_call(:user_id, _from, state) do
    {:reply, @user_id, state}
  end

  def handle_call(:username, _from, state) do
    {:reply, @username, state}
  end

  defp calculate_pp(user, file_md5, mods, game_mode) do
    Logger.warn "#{Color.username(user.username)} sent pp request: file_md5=#{file_md5} mods=#{mods} game_mode=#{game_mode}"
    trucksu_url = Application.get_env(:game, :trucksu_url)
    server_cookie = Application.get_env(:game, :server_cookie)
    case HTTPoison.get(trucksu_url <> "/api/v1/pp-calc", [], params: [{"file_md5", file_md5}, {"mods", "#{mods}"}, {"m", "#{game_mode}"}, {"c", server_cookie}]) do
      {:ok, %HTTPoison.Response{body: body}} ->
        case Poison.decode body do
          {:ok, %{"pp" => pp, "osu_beatmap" => %{"version" => version, "title" => title, "difficultyrating" => stars, "creator" => creator, "artist" => artist}}} ->

            message = "#{pp}pp for #{artist} - #{title} (#{creator}) [#{version}] (#{stars}*) (mods: #{mods})"
            Logger.warn "Sending message to #{user.username}: #{message}"
            packet = Packet.send_message(@username, message, user.username, @user_id)
            StateServer.Client.enqueue(user.id, packet)

          {:error, error} ->
            Logger.error "Unable to calculate pp for file_md5=#{file_md5} mods=#{mods} game_mode=#{game_mode}"
            Logger.error inspect error

          _ ->
            Logger.error "Unable to calculate pp for file_md5=#{file_md5} mods=#{mods} game_mode=#{game_mode}"
            Logger.error inspect body
        end
      {:error, error} ->
        Logger.error "Unable to calculate pp for file_md5=#{file_md5} mods=#{mods} game_mode=#{game_mode}"
        Logger.error inspect error
    end
  end
end
