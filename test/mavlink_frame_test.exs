defmodule XMAVLink.Test.Frame do
  use ExUnit.Case, async: true

  alias XMAVLink.Frame

  @signed_incompatible_flags 0x01
  @unknown_incompatible_flags 0x02
  @signed_unknown_incompatible_flags 0x03
  @signature_hash <<8, 9, 10, 11, 12, 13>>
  @signature <<99, 0x010203040506::little-unsigned-integer-size(48), @signature_hash::binary>>
  @secret_key :binary.copy(<<42>>, 32)
  @link_id 17
  @timestamp 0x010203040506

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

  test "frame parser resynchronizes after leading non-MAVLink bytes" do
    frame =
      Frame.pack_frame(%Frame{
        version: 2,
        sequence_number: 7,
        source_system: 1,
        source_component: 1,
        message_id: 24,
        payload: <<1, 2, 3>>,
        crc_extra: 0
      })

    tail = <<10, 11, 12>>
    raw = <<0, 1, 2, 3>> <> frame.mavlink_2_raw <> tail

    assert {%Frame{} = parsed_frame, ^tail} = Frame.binary_to_frame_and_tail(raw)
    assert parsed_frame.version == 2
    assert parsed_frame.sequence_number == 7
    assert parsed_frame.source_system == 1
    assert parsed_frame.source_component == 1
    assert parsed_frame.message_id == 24
    assert parsed_frame.payload == <<1, 2, 3>>
  end

  test "malformed byte streams never crash frame parsing or unpack validation" do
    for seed <- 0..400 do
      raw = deterministic_binary(seed, rem(seed * 37, 160))

      result = Frame.binary_to_frame_and_tail(raw)
      assert_frame_parse_result_shape(result, raw)

      case result do
        {%Frame{} = frame, _tail} ->
          assert_validate_and_unpack_result_shape(Frame.validate_and_unpack(frame, Common))

        _ ->
          :ok
      end
    end
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

  test "MAVLink 2 frame signing appends a valid signature trailer" do
    frame =
      Frame.pack_frame(%Frame{
        version: 2,
        sequence_number: 7,
        source_system: 1,
        source_component: 1,
        message_id: 24,
        payload: <<1, 2, 0>>,
        crc_extra: 0
      })

    assert {:ok, %Frame{} = signed_frame} =
             Frame.sign_frame(frame, @secret_key, @link_id, @timestamp)

    assert Frame.signed?(signed_frame)

    expected_payload = <<1, 2>>

    expected_body =
      <<2, 1, 0, 7, 1, 1, 24::little-unsigned-integer-size(24), expected_payload::binary>>

    expected_checksum = expected_checksum(expected_body, frame.crc_extra)
    expected_signature_prefix = <<@link_id, @timestamp::little-unsigned-integer-size(48)>>

    expected_signature_hash =
      :crypto.hash(
        :sha256,
        @secret_key <> <<0xFD>> <> expected_body <> expected_checksum <> expected_signature_prefix
      )
      |> binary_part(0, 6)

    expected_raw =
      <<0xFD>> <>
        expected_body <> expected_checksum <> expected_signature_prefix <> expected_signature_hash

    assert signed_frame.mavlink_2_raw == expected_raw
    assert signed_frame.payload_length == 2
    assert signed_frame.payload == expected_payload
    assert signed_frame.incompatible_flags == @signed_incompatible_flags
    assert signed_frame.signature.link_id == @link_id
    assert signed_frame.signature.timestamp == @timestamp
    assert signed_frame.signature.signature == expected_signature_hash

    assert {%Frame{} = parsed_frame, <<>>} = Frame.binary_to_frame_and_tail(expected_raw)
    assert parsed_frame.signature == signed_frame.signature
    assert :signed_frame_unsupported = Frame.validate_and_unpack(parsed_frame, Common)
    assert :ok = Frame.validate_signature(parsed_frame, @secret_key)

    assert {:error, :signature_invalid} =
             Frame.validate_signature(parsed_frame, wrong_secret_key())
  end

  test "MAVLink 2 frame signing rejects invalid inputs" do
    %Frame{} =
      unsigned_frame =
      Frame.pack_frame(%Frame{
        version: 2,
        sequence_number: 7,
        source_system: 1,
        source_component: 1,
        message_id: 24,
        payload: <<1, 2, 3>>,
        crc_extra: 0
      })

    mavlink_1_frame =
      Frame.pack_frame(%Frame{
        version: 1,
        sequence_number: 7,
        source_system: 1,
        source_component: 1,
        message_id: 24,
        payload: <<>>,
        crc_extra: 0
      })

    assert {:error, :mavlink_1_not_signable} =
             Frame.sign_frame(mavlink_1_frame, @secret_key, @link_id, @timestamp)

    assert {:error, :invalid_secret_key} =
             Frame.sign_frame(unsigned_frame, <<1, 2, 3>>, @link_id, @timestamp)

    assert {:error, :invalid_link_id} =
             Frame.sign_frame(unsigned_frame, @secret_key, 256, @timestamp)

    assert {:error, :invalid_timestamp} =
             Frame.sign_frame(unsigned_frame, @secret_key, @link_id, 0x1_0000_0000_0000)

    assert {:error, :missing_crc_extra} =
             Frame.sign_frame(
               %Frame{unsigned_frame | crc_extra: nil},
               @secret_key,
               @link_id,
               @timestamp
             )

    assert {:error, :invalid_crc_extra} =
             Frame.sign_frame(
               %Frame{unsigned_frame | crc_extra: 256},
               @secret_key,
               @link_id,
               @timestamp
             )

    assert {:error, :missing_mavlink_2_raw} =
             Frame.sign_frame(
               %Frame{unsigned_frame | mavlink_2_raw: nil},
               @secret_key,
               @link_id,
               @timestamp
             )

    unsupported_incompatible_frame = %Frame{
      unsigned_frame
      | mavlink_2_raw:
          <<0xFD, 3, @unknown_incompatible_flags, 0, 7, 1, 1,
            24::little-unsigned-integer-size(24), 1, 2, 3, 0::little-unsigned-integer-size(16)>>
    }

    assert {:error, :unsupported_incompatible_flags} =
             Frame.sign_frame(unsupported_incompatible_frame, @secret_key, @link_id, @timestamp)

    assert {:error, :checksum_invalid} =
             Frame.sign_frame(
               corrupt_mavlink_2_checksum(unsigned_frame),
               @secret_key,
               @link_id,
               @timestamp
             )

    assert {:ok, signed_frame} =
             Frame.sign_frame(unsigned_frame, @secret_key, @link_id, @timestamp)

    assert {:error, :already_signed} =
             Frame.sign_frame(signed_frame, @secret_key, @link_id, @timestamp)
  end

  test "MAVLink 2 signature validation rejects unsigned and corrupted frames" do
    frame =
      Frame.pack_frame(%Frame{
        version: 2,
        sequence_number: 7,
        source_system: 1,
        source_component: 1,
        message_id: 24,
        payload: <<1, 2, 3>>,
        crc_extra: 0
      })

    assert {:error, :unsigned_frame} = Frame.validate_signature(frame, @secret_key)

    assert {:ok, %Frame{} = signed_frame} =
             Frame.sign_frame(frame, @secret_key, @link_id, @timestamp)

    assert {:error, :signature_invalid} =
             Frame.validate_signature(corrupt_signature(signed_frame), @secret_key)

    assert {:error, :invalid_mavlink_2_frame} =
             Frame.validate_signature(
               %Frame{signed_frame | mavlink_2_raw: nil},
               @secret_key
             )
  end

  defp signed_frame_raw(incompatible_flags \\ @signed_incompatible_flags) do
    <<0xFD, 0, incompatible_flags, 0, 7, 1, 1, 0::little-unsigned-integer-size(24),
      0::little-unsigned-integer-size(16)>> <> @signature
  end

  defp expected_checksum(frame_body, crc_extra) do
    checksum =
      frame_body
      |> XMAVLink.Utils.x25_crc()
      |> XMAVLink.Utils.x25_crc([crc_extra])

    <<checksum::little-unsigned-integer-size(16)>>
  end

  defp corrupt_mavlink_2_checksum(%Frame{mavlink_2_raw: raw} = frame) do
    checksum_offset = byte_size(raw) - 2

    <<prefix::binary-size(^checksum_offset), checksum::little-unsigned-integer-size(16)>> = raw

    %Frame{
      frame
      | mavlink_2_raw:
          prefix <> <<Bitwise.bxor(checksum, 0xFFFF)::little-unsigned-integer-size(16)>>
    }
  end

  defp corrupt_signature(%Frame{mavlink_2_raw: raw} = frame) do
    signature_offset = byte_size(raw) - 6

    <<prefix::binary-size(^signature_offset), signature_head, signature_tail::binary-size(5)>> =
      raw

    %Frame{
      frame
      | mavlink_2_raw: prefix <> <<Bitwise.bxor(signature_head, 0xFF)>> <> signature_tail
    }
  end

  defp deterministic_binary(_seed, 0), do: <<>>

  defp deterministic_binary(seed, length) do
    chunks =
      0..div(length + 31, 32)
      |> Enum.map(fn counter ->
        :crypto.hash(:sha256, :erlang.term_to_binary({seed, counter}))
      end)
      |> IO.iodata_to_binary()

    binary_part(chunks, 0, length)
  end

  defp assert_frame_parse_result_shape(:not_a_frame, _raw), do: :ok

  defp assert_frame_parse_result_shape({nil, rest}, raw) when is_binary(rest) do
    assert byte_size(rest) <= byte_size(raw)
  end

  defp assert_frame_parse_result_shape({%Frame{} = frame, rest}, raw) when is_binary(rest) do
    assert byte_size(rest) <= byte_size(raw)
    assert frame.version in [1, 2]
    assert is_integer(frame.payload_length)
    assert is_integer(frame.sequence_number)
    assert is_integer(frame.source_system)
    assert is_integer(frame.source_component)
    assert is_integer(frame.message_id)
    assert is_binary(frame.payload)
  end

  defp assert_validate_and_unpack_result_shape({:ok, %Frame{}}), do: :ok
  defp assert_validate_and_unpack_result_shape(:failed_to_unpack), do: :ok
  defp assert_validate_and_unpack_result_shape(:checksum_invalid), do: :ok
  defp assert_validate_and_unpack_result_shape(:unknown_message), do: :ok
  defp assert_validate_and_unpack_result_shape(:signed_frame_unsupported), do: :ok

  defp wrong_secret_key, do: :binary.copy(<<43>>, 32)
end
