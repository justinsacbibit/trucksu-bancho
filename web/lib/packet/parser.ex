defmodule Game.Packet.Decoder do
  require Logger
  alias Game.StateServer

  defp unpack_num(data, size, signed) do
    if signed do
      <<num::little-size(size), rest::binary>> = data
      {num, rest}
    else
      <<num::unsigned-little-size(size), rest::binary>> = data
      {num, rest}
    end
  end

  defp unpack(<<0, rest::binary>>, :string), do: {"", rest}
  defp unpack(<<0x0b, rest::binary>>, :string) do
    {len, rest} = decode_uleb128(rest)
    <<str::binary-size(len)-unit(8), rest::binary>> = rest
    {str, rest}
  end

  defp unpack(data, :uint64), do: unpack_num(data, 64, false)
  defp unpack(data, :uint32), do: unpack_num(data, 32, false)
  defp unpack(data, :uint16), do: unpack_num(data, 16, false)
  defp unpack(data, :uint8), do: unpack_num(data, 8, false)
  defp unpack(data, :int64), do: unpack_num(data, 64, true)
  defp unpack(data, :int32), do: unpack_num(data, 32, true)
  defp unpack(data, :int16), do: unpack_num(data, 16, true)
  defp unpack(data, :int8), do: unpack_num(data, 8, true)
  defp unpack(data, :bytes), do: {data, <<>>}

  defp decode_with_format(data, []) do
    # TODO: Log if data is not empty
    #Logger.error inspect data
    [{:undecoded, data}]
  end
  defp decode_with_format(data, [{key, type}|format]) do
    {result, data} = unpack(data, type)
    [{key, result}|decode_with_format(data, format)]
  end

  defp channel_join(data) do
    decode_with_format(data, [channel: :string])
  end

  defp channel_part(data) do
    decode_with_format(data, [channel: :string])
  end

  defp send_public_message(data) do
    decode_with_format(data, [
      unknown: :string,
      message: :string,
      to: :string,
    ])
  end

  defp send_private_message(data) do
    decode_with_format(data, [
      unknown: :string,
      message: :string,
      to: :string,
      unknown2: :string,
    ])
  end

  defp change_action(data) do
    decode_with_format(data, [
      action_id: :uint8,
      action_text: :string,
      action_md5: :string,
      action_mods: :uint32,
      game_mode: :uint8,
    ])
  end

  defp user_stats_request(data) do
    decode_with_format(data, [
      unknown1: :uint8,
      unknown2: :uint8,
      user_id: :int32,
    ])
  end

  defp spectate_frames(data) do
    decode_with_format(data, [
      data: :bytes,
    ])
  end

  defp start_spectating(data) do
    decode_with_format(data, [
      user_id: :int32,
    ])
  end

  defp add_remove_friend(data) do
    decode_with_format(data, [
      friend_id: :int32,
    ])
  end

  ## Multiplayer packets

  defp match_change_slot(data) do
    decode_with_format(data, [
      slot_id: :int32,
    ])
  end

  defp match_settings(data) do
    format = [
      match_id: :uint16,
      in_progress: :uint8,
      unknown: :uint8,
      mods: :uint32,
      match_name: :string,
      match_password: :string,
      beatmap_name: :string,
      beatmap_id: :uint32,
      beatmap_md5: :string,
    ]

    format = format ++ Enum.map 0..15, fn(slot_status_id) ->
      {:"slot_#{slot_status_id}_status", :uint8}
    end

    format = format ++ Enum.map 0..15, fn(slot_team_id) ->
      {:"slot_#{slot_team_id}_team", :uint8}
    end

    decoded_data = decode_with_format(data, format)
    format = format ++
    for slot_id <- 0..15,
        status = decoded_data[:"slot_#{slot_id}_status"],
        status != StateServer.Client.slot_status_free,
        status != StateServer.Client.slot_status_locked do
      # occupied slot
      {:"slot_#{slot_id}_user_id", :int32}
    end

    format = format ++ [
      host_user_id: :int32,
      game_mode: :int8,
      scoring_type: :int8,
      team_type: :int8,
      free_mods: :int8,
    ]

    decode_with_format(data, format)
  end

  defp create_match(data) do
    match_settings(data)
  end

  defp match_lock(data) do
    decode_with_format(data, [
      slot_id: :int32,
    ])
  end

  defp match_change_settings(data) do
    match_settings(data)
  end

  defp match_change_mods(data) do
    decode_with_format(data, [
      mods: :int32,
    ])
  end

  defp match_frames(data) do
    decode_with_format(data, [
      data: :bytes,
    ])
  end

  defp decode_packet(0, data), do: change_action(data)
  defp decode_packet(1, data), do: send_public_message(data)
  defp decode_packet(2, _), do: [] # logout
  defp decode_packet(3, _), do: [] # requestStatusUpdate
  defp decode_packet(4, _), do: [] # ping
  defp decode_packet(16, data), do: start_spectating(data)
  defp decode_packet(18, data), do: spectate_frames(data)
  defp decode_packet(25, data), do: send_private_message(data)
  defp decode_packet(29, _data), do: [] # partLobby
  defp decode_packet(30, _data), do: [] # joinLobby
  defp decode_packet(31, data), do: create_match(data)
  defp decode_packet(38, data), do: match_change_slot(data)
  defp decode_packet(40, data), do: match_lock(data)
  defp decode_packet(41, data), do: match_change_settings(data)
  defp decode_packet(47, data), do: match_frames(data)
  defp decode_packet(51, data), do: match_change_mods(data)
  defp decode_packet(63, data), do: channel_join(data)
  defp decode_packet(68, _), do: [] # beatmapInfoRequest
  defp decode_packet(73, data), do: add_remove_friend(data)
  defp decode_packet(74, data), do: add_remove_friend(data)
  defp decode_packet(78, data), do: channel_part(data)
  defp decode_packet(79, _), do: [] # receiveUpdates
  defp decode_packet(85, data), do: user_stats_request(data)
  defp decode_packet(97, _), do: [] # userPresenceRequest
  defp decode_packet(_, data), do: decode_with_format(data, [])

  def decode_uleb128(binary) do
    {size, bitstring, tail} = pdecode_uleb128(binary, 0, <<>>)
    <<value::unsigned-integer-size(size)>> = bitstring
    {value, tail}
  end

  defp pdecode_uleb128(<<0::size(1), chunk::bitstring-size(7), tail::binary>>, size, acc) do
    {size + 7, <<chunk::bitstring, acc::bitstring>>, tail}
  end
  defp pdecode_uleb128(<<1::size(1), chunk::bitstring-size(7), tail::binary>>, size, acc) do
    pdecode_uleb128(tail, size + 7, <<chunk::bitstring, acc::bitstring>>)
  end

  @doc """
  Decodes the given `stacked_packets` binary.

  Returns a list of decoded packets, each in the form of a tuple `{packet_id, data}`,
  where `data` is a keyword list.

  ## Examples

      iex> Decoder.decode_packets(<packet data for send_public_message>)
      [{packet_id, [unknown: "", message: "Hey!", to: "#osu"]}]
  """
  def decode_packets(stacked_packets) do
    decoded_packets = separate_packets(stacked_packets)
    |> Enum.map(fn({packet_id, data}) ->
      try do
        {packet_id, decode_packet(packet_id, data)}
      rescue
        _e in FunctionClauseError ->
          Logger.error "Got FunctionClauseError when decoding packet with id #{packet_id}"
          Logger.error "Data: #{inspect data}"
          {}
      end
    end)

    # Filter out empty tuples
    for {_, _} = decoded_packet <- decoded_packets, do: decoded_packet
  end

  defp separate_packets(<<>>) do
    []
  end
  defp separate_packets(stacked_packets) do
    <<packet_id::little-unsigned-integer-size(16),
      0,
      data_len::little-unsigned-integer-size(32),
      data::binary-size(data_len)-unit(8),
      rest::binary>> = stacked_packets

    [{packet_id, data} | separate_packets(rest)]

    ## packet ID (2 bytes) + null byte (1 byte) + data length (4 bytes) + data (len bytes)
    #size = 2 + 1 + 4 + len
    #<<packet :: binary-size(size)-unit(8), rest :: binary>> = stacked_packets

    #[packet | separate_packets(rest)]
  end
end

