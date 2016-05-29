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

            case file_md5 do
              "" ->
                message = "PP calculation currently does not work from song select (or when you're afk). Make sure you're playing/watching a map"
                Logger.warn "Sending message to #{user.username}: #{message}"
                packet = Packet.send_message(@username, message, user.username, @user_id)
                StateServer.Client.enqueue(user.id, packet)
              _ ->
                calculate_pp(user, file_md5, mods, game_mode)
            end
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

  defp mods_to_string(mods) do
    mod_map = [
      {"NF", 1},
      {"EZ", 2},
      {"HD", 8},
      {"HR", 16},
      {"SD", 32},
      {"DT", 64},
      {"RX", 128},
      {"HT", 256},
      {"NC", 512},
      {"FL", 1024},
      {"AU", 2048},
      {"SO", 4096},
      {"AP", 8192},
      {"PF", 16384},
    ]

    mod_strs = for {mod_str, mod_val} <- mod_map, (mods &&& mod_val) > 0 do
      mod_str
    end

    Enum.join(mod_strs, ",")
  end

  defp calculate_pp(user, file_md5, mods, game_mode) do
    Logger.warn "#{Color.username(user.username)} sent pp request: file_md5=#{file_md5} mods=#{mods} game_mode=#{game_mode}"
    trucksu_api_url = Application.get_env(:game, :trucksu_api_url)
    server_cookie = Application.get_env(:game, :server_cookie)
    case HTTPoison.get(trucksu_api_url <> "/v1/pp-calc", [], params: [{"file_md5", file_md5}, {"mods", "#{mods}"}, {"m", "#{game_mode}"}, {"c", server_cookie}]) do
      {:ok, %HTTPoison.Response{body: body}} ->
        case Poison.decode body do
          {:ok, %{"pp" => pp, "osu_beatmap" => %{"version" => version, "title" => title, "difficultyrating" => stars, "creator" => creator, "artist" => artist}}} ->

            mod_string = mods_to_string(mods)
            mod_string = if mod_string != "" do
              " (mods: +#{mod_string})"
            else
              ""
            end
            message = "#{pp}pp for SS #{artist} - #{title} (#{creator}) [#{version}] (#{((stars * 100) |> Float.round) / 100}*)#{mod_string}"
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

        message = "I wasn't able to calculate the pp for that map - you might have an outdated version"
        Logger.warn "Sending message to #{user.username}: #{message}"
        packet = Packet.send_message(@username, message, user.username, @user_id)
        StateServer.Client.enqueue(user.id, packet)
    end
  end
end
