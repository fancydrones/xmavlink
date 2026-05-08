defmodule XMAVLink.Test.Frame do
  use ExUnit.Case, async: true

  alias XMAVLink.Frame

  @signed_incompatible_flags 0x01
  @unknown_incompatible_flags 0x02
  @signed_unknown_incompatible_flags 0x03
  @signature_hash <<8, 9, 10, 11, 12, 13>>
  @signature <<99, 0x010203040506::little-unsigned-integer-size(48), @signature_hash::binary>>

  test "MAVLink 2 signed frames parse the signature trailer and tail" do
    tail = <<0xFE, 0, 0, 1, 1, 0, 0, 0>>
    raw = signed_frame_raw() <> tail

    assert {%Frame{signature: signature, mavlink_2_raw: signed_raw} = frame, ^tail} =
             Frame.binary_to_frame_and_tail(raw)

    assert Frame.signed?(frame)
    assert %Frame.Signature{} = signature
    assert signature.link_id == 99
    assert signature.timestamp == 0x010203040506
    assert signature.signature == @signature_hash
    assert signed_raw == signed_frame_raw()
  end

  test "MAVLink 2 signed frames are not unpacked before signature validation exists" do
    assert {%Frame{} = frame, <<>>} = Frame.binary_to_frame_and_tail(signed_frame_raw())

    assert :signed_frame_unsupported = Frame.validate_and_unpack(frame, Common)
  end

  test "MAVLink 2 signed frames with additional unsupported flags consume the signature" do
    tail = <<0xFE, 0, 0, 1, 1, 0, 0, 0>>
    raw = signed_frame_raw(@signed_unknown_incompatible_flags) <> tail

    assert {nil, ^tail} = Frame.binary_to_frame_and_tail(raw)
  end

  test "MAVLink 2 frames with unknown incompatible flags are dropped" do
    tail = <<0xFE, 0, 0, 1, 1, 0, 0, 0>>

    raw =
      <<0xFD, 0, @unknown_incompatible_flags, 0, 7, 1, 1, 0::little-unsigned-integer-size(24),
        0::little-unsigned-integer-size(16)>> <>
        tail

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

  defp signed_frame_raw(incompatible_flags \\ @signed_incompatible_flags) do
    <<0xFD, 0, incompatible_flags, 0, 7, 1, 1, 0::little-unsigned-integer-size(24),
      0::little-unsigned-integer-size(16)>> <> @signature
  end
end
