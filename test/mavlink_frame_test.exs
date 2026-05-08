defmodule XMAVLink.Test.Frame do
  use ExUnit.Case, async: true

  alias XMAVLink.Frame

  @signed_incompatible_flags 0x01

  test "MAVLink 2 signed frames with unsupported incompatible flags consume the signature" do
    signature = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13>>
    tail = <<0xFE, 0, 0, 1, 1, 0, 0, 0>>

    raw =
      <<0xFD, 0, @signed_incompatible_flags, 0, 7, 1, 1, 0::little-unsigned-integer-size(24),
        0::little-unsigned-integer-size(16)>> <>
        signature <> tail

    assert {nil, ^tail} = Frame.binary_to_frame_and_tail(raw)
  end

  test "incomplete MAVLink 2 signed frames remain buffered" do
    raw =
      <<0xFD, 0, @signed_incompatible_flags, 0, 7, 1, 1, 0::little-unsigned-integer-size(24),
        0::little-unsigned-integer-size(16)>>

    assert {nil, ^raw} = Frame.binary_to_frame_and_tail(raw)
  end

  test "MAVLink 2 packing preserves empty payloads as length zero" do
    frame =
      Frame.pack_frame(%Frame{
        version: 2,
        sequence_number: 0,
        source_system: 1,
        source_component: 1,
        message_id: 0,
        payload: <<>>,
        crc_extra: 0
      })

    assert <<0xFD, 0, _rest::binary>> = frame.mavlink_2_raw
    assert byte_size(frame.mavlink_2_raw) == 12
  end
end
