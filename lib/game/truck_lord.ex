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
      pp: %{},
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

  def handle_cast({:receive_message, message, user}, %{pp: pp_state} = state) do
    Logger.warn "#{user.username} to TrucksuLord received message \"#{message}\""

    pp_state = case message do
      <<1>> <> "ACTION is listening to [" <> url_and_stuff ->
        case String.split(url_and_stuff, " ") do
          ["http://osu.ppy.sh/b/" <> beatmap_id | _] ->
            handle_beatmap_id_str(pp_state, user, beatmap_id)
          s ->
            Logger.error "Received beatmap pp request, but was unable to parse out the beatmap id"
            Logger.error inspect s
            pp_state
        end
      <<1>> <> "ACTION is playing [" <> url_and_stuff ->
        case String.split(url_and_stuff, " ") do
          ["http://osu.ppy.sh/b/" <> beatmap_id | rest] ->
            mods = for "+" <> mod <- rest, do: mod
            mods = convert_mod_strings(mods)
            handle_beatmap_id_str(pp_state, user, beatmap_id, mods)
          s ->
            Logger.error "Received beatmap pp request, but was unable to parse out the beatmap id"
            Logger.error inspect s
            pp_state
        end
      s ->
        Logger.error "Received beatmap pp request, but was unable to parse the message"
        Logger.error inspect s
        pp_state
    end

    {:noreply, %{state | pp: pp_state}}
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

  defp convert_mod_strings(mod_strings) do
    Enum.reduce(mod_strings, 0, fn mod_string, mods ->
      mod = case mod_string do
        "Hidden" -> 8
        "Hidden" <> <<1>> -> 8
        "HardRock" -> 16
        "HardRock" <> <<1>> -> 16
        "DoubleTime" -> 64
        "DoubleTime" <> <<1>> -> 64
        _ -> 0
      end

      mods ||| mod
    end)
  end

  defp handle_beatmap_id_str(pp_state, user, beatmap_id, mods \\ 0) do
    case Integer.parse(beatmap_id) do
      {beatmap_id, _} ->
        Logger.warn "#{user.username} sent pp request for #{beatmap_id} with mods #{mods}"
        trucksu_url = Application.get_env(:game, :trucksu_url)
        server_cookie = Application.get_env(:game, :server_cookie)
        case HTTPoison.get(trucksu_url <>"/api/v1/pp-calc", [], params: [{"b", "#{beatmap_id}"}, {"mods", "#{mods}"}, {"m", "0"}, {"c", server_cookie}]) do
          {:ok, %HTTPoison.Response{body: body}} ->
            case Poison.decode body do
              {:ok, %{"pp" => pp, "osu_beatmap" => %{"version" => version, "title" => title, "difficultyrating" => stars, "creator" => creator, "artist" => artist}}} ->

                message = "#{pp}pp for #{artist} - #{title} (#{creator}) [#{version}] (#{stars}*) (mods: #{mods})"
                Logger.warn "Sending message to #{user.username}: #{message}"
                packet = Packet.send_message(@username, message, user.username, @user_id)
                StateServer.Client.enqueue(user.id, packet)

                Map.put(pp_state, user.id, %{beatmap_id: beatmap_id})

              {:error, error} ->
                Logger.error "Unable to calculate pp for #{beatmap_id} with #{mods}"
                Logger.error inspect error
                pp_state

              _ ->
                Logger.error "Unable to calculate pp for #{beatmap_id} with #{mods}"
                Logger.error inspect body
                pp_state
            end
          {:error, error} ->
            Logger.error "Unable to calculate pp for #{beatmap_id} with #{mods}"
            Logger.error inspect error
            pp_state
        end

      s ->
        Logger.error "Received beatmap pp request, but was unable to parse the beatmap id to an int"
        Logger.error inspect s
        pp_state
    end
  end
end

