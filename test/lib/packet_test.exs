defmodule PacketTest do
  @moduledoc """
  This module tests that the Packet module packs data into the correct
  binary format.

  Words in packets are represented in little-endian format. This means
  that a 16-bit integer with a value of 5 will be represented as
    0x50 in hex, which is
    0b01010000

  The overall format of a packet is
    packet ID (int16) - The purpose of the packet, e.g. user login/logout
    empty byte (0x0)
    data length (int32) - The length of the following data (number of bytes)
    data - Packet data
  """

  use ExUnit.Case
  alias Game.Packet

  test "integer data" do
    expected = <<5::little-size(16)>> <> <<0>> <> <<4::little-size(32)>> <> <<-1::little-size(32)>>
    assert Packet.login_failed == expected
  end

  #test "user_panel" do
    #expected = <<83, 0, 0, 29, 0, 0, 0, 110, 25, 24, 0, 11, 8, 67, 111, 111, 107, 105, 101, 122, 105, 24, 1, 0, 205, 204, 140, 63, 205, 204, 140, 63, 241, 8, 0, 0>>

    #user = %{id: 1579374, username: "Truck Driver"}
    #assert Packet.user_panel(user) == expected
  #end

  #test "user_stats" do
    #expected = <<11, 0, 0, 46, 0, 0, 0, 110, 25, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 187, 68, 190, 60, 1, 0, 0, 0, 27, 47, 125, 63, 253, 221, 0, 0, 109, 247, 91, 34, 7, 0, 0, 0, 3, 0, 0, 0, 26, 44>>

    #user = %{id: 1579374}
    #assert Packet.user_stats(user) == expected
  #end
end
