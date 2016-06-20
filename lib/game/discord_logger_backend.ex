defmodule Game.DiscordLoggerBackend do
  use GenEvent

  def handle_event({level, _gl, {Logger, msg, ts, _md}}, state) do
    if Mix.env == :prod and Logger.compare_levels(level, :error) != :lt do
      time = Timex.datetime(ts) |> Timex.format("{h24}:{m}:{s}")
      case time do
        {:ok, time} ->
          message = "#{time} [#{level}] #{msg}"
          bot_url = Application.get_env(:game, :bot_url)
          data = %{"message" => message, "application" => "trucksu-bancho"}
          json = Poison.encode! data
          result = HTTPoison.post bot_url <> "/log", json, [{"Content-Type", "application/json"}], timeout: 20000, recv_timeout: 20000
          :io.put_chars :user, "Sent log to bot: \"#{message}\", result: #{inspect result}"
        _ -> :ok
      end
    end
    {:ok, state}
  end
end
