defmodule XMAVLink.Frame.Signature do
  @moduledoc """
  MAVLink 2 signed-frame trailer.

  MAVLink 2 signing appends a 13-byte trailer after the checksum:
  one-byte link id, 48-bit timestamp, and 48-bit signature.
  """

  defstruct link_id: nil,
            timestamp: nil,
            signature: nil

  @type t :: %XMAVLink.Frame.Signature{
          link_id: 0..255,
          timestamp: 0..281_474_976_710_655,
          signature: <<_::48>>
        }
end

defmodule XMAVLink.Frame do
  @moduledoc """
  Represent and work with MAVLink v1/2 message frames
  """

  require Logger

  import Bitwise
  import XMAVLink.Utils, only: [x25_crc: 1, x25_crc: 2]

  @mavlink_2_signature_flag 0x01
  @mavlink_2_signature_length 13
  @mavlink_2_supported_incompatible_flags @mavlink_2_signature_flag

  defstruct [
    # Which raw attributes are populated?
    version: nil,
    payload_length: nil,
    # MAVLink 2 only
    incompatible_flags: 0,
    # MAVLink 2 only
    compatible_flags: 0,
    sequence_number: nil,
    source_system: nil,
    source_component: nil,
    # Default to broadcast assumed elsewhere
    target_system: 0,
    target_component: 0,
    target: nil,
    message_id: nil,
    crc_extra: nil,
    payload: nil,
    checksum: nil,
    # MAVLink 2 signing only
    signature: nil,
    # Original binary frame
    mavlink_1_raw: nil,
    mavlink_2_raw: nil,
    message: nil
  ]

  @type message :: XMAVLink.Message.t()
  @type version :: 1 | 2
  @type t :: %XMAVLink.Frame{
          version: version,
          payload_length: 0..255,
          incompatible_flags: non_neg_integer,
          compatible_flags: non_neg_integer,
          sequence_number: 0..255,
          source_system: 1..255,
          source_component: 1..255,
          target_system: 0..255,
          target_component: 0..255,
          target: :broadcast | :system | :system_component | :component,
          message_id: XMAVLink.Types.message_id(),
          crc_extra: XMAVLink.Types.crc_extra(),
          payload: binary,
          checksum: 0..65_535,
          signature: XMAVLink.Frame.Signature.t() | nil,
          mavlink_1_raw: binary,
          mavlink_2_raw: binary,
          message: message
        }

  @spec binary_to_frame_and_tail(binary) ::
          {XMAVLink.Frame.t(), binary} | {nil, binary} | :not_a_frame
  # MAVLink version 1
  def binary_to_frame_and_tail(
        raw_and_rest =
          <<0xFE, payload_length::unsigned-integer-size(8),
            sequence_number::unsigned-integer-size(8), source_system::unsigned-integer-size(8),
            source_component::unsigned-integer-size(8), message_id::unsigned-integer-size(8),
            payload::binary-size(payload_length), checksum::little-unsigned-integer-size(16),
            rest::binary>>
      ) do
    {
      struct(XMAVLink.Frame,
        version: 1,
        payload_length: payload_length,
        sequence_number: sequence_number,
        source_system: source_system,
        source_component: source_component,
        message_id: message_id,
        payload: payload,
        checksum: checksum,
        mavlink_1_raw:
          binary_part(
            raw_and_rest,
            0,
            byte_size(raw_and_rest) - byte_size(rest)
          )
      ),
      rest
    }
  end

  # MAVLink version 2
  def binary_to_frame_and_tail(
        raw_and_rest =
          <<0xFD, payload_length::unsigned-integer-size(8),
            incompatible_flags::unsigned-integer-size(8),
            compatible_flags::unsigned-integer-size(8), sequence_number::unsigned-integer-size(8),
            source_system::unsigned-integer-size(8), source_component::unsigned-integer-size(8),
            message_id::little-unsigned-integer-size(24), payload::binary-size(payload_length),
            checksum::little-unsigned-integer-size(16), rest::binary>>
      ) do
    frame =
      struct(XMAVLink.Frame,
        version: 2,
        payload_length: payload_length,
        incompatible_flags: incompatible_flags,
        compatible_flags: compatible_flags,
        sequence_number: sequence_number,
        source_system: source_system,
        source_component: source_component,
        message_id: message_id,
        payload: payload,
        checksum: checksum
      )

    cond do
      unsupported_incompatible_flags?(incompatible_flags) and signed?(incompatible_flags) ->
        drop_incompatible_signed_frame(raw_and_rest, rest)

      unsupported_incompatible_flags?(incompatible_flags) ->
        {nil, rest}

      signed?(incompatible_flags) ->
        signed_frame_and_tail(raw_and_rest, frame, rest)

      true ->
        {
          struct(frame,
            mavlink_2_raw:
              binary_part(
                raw_and_rest,
                0,
                byte_size(raw_and_rest) - byte_size(rest)
              )
          ),
          rest
        }
    end
  end

  def binary_to_frame_and_tail(unfinished_mavlink_1_frame = <<0xFE, _::binary>>),
    do: {nil, unfinished_mavlink_1_frame}

  def binary_to_frame_and_tail(unfinished_mavlink_2_frame = <<0xFD, _::binary>>),
    do: {nil, unfinished_mavlink_2_frame}

  def binary_to_frame_and_tail(<<_, rest::binary>>), do: binary_to_frame_and_tail(rest)
  def binary_to_frame_and_tail(<<>>), do: :not_a_frame

  @spec validate_and_unpack(XMAVLink.Frame.t(), module) ::
          {:ok, XMAVLink.Frame.t()}
          | :failed_to_unpack
          | :checksum_invalid
          | :unknown_message
          | :signed_frame_unsupported
  def validate_and_unpack(frame = %XMAVLink.Frame{version: 2}, dialect) do
    if signed?(frame) do
      :signed_frame_unsupported
    else
      validate_unsigned_and_unpack(frame, dialect)
    end
  end

  def validate_and_unpack(frame, dialect), do: validate_unsigned_and_unpack(frame, dialect)

  defp validate_unsigned_and_unpack(
         frame = %XMAVLink.Frame{message_id: message_id, version: version, payload: payload},
         dialect
       ) do
    case apply(dialect, :msg_attributes, [message_id]) do
      {:ok, crc_extra, expected_length, target} ->
        if frame.checksum ==
             :binary.bin_to_list(
               %{1 => frame.mavlink_1_raw, 2 => frame.mavlink_2_raw}[frame.version],
               {1, frame.payload_length + %{1 => 5, 2 => 9}[frame.version]}
             )
             |> x25_crc()
             |> x25_crc([crc_extra]) do
          # Only used to undo MAVLink 2 payload truncation
          payload_truncated_length = 8 * (expected_length - frame.payload_length)
          # Too many ways for unpack to fail with dodgy messages...
          try do
            case apply(dialect, :unpack, [
                   message_id,
                   version,
                   payload <>
                     if(payload_truncated_length > 0 and version > 1,
                       do: <<0::size(payload_truncated_length)>>,
                       else: <<>>
                     )
                 ]) do
              {:ok, message} ->
                case target do
                  :broadcast ->
                    {:ok,
                     struct(frame,
                       message: message,
                       target_system: 0,
                       target_component: 0,
                       target: target,
                       crc_extra: crc_extra
                     )}

                  :system ->
                    {:ok,
                     struct(frame,
                       message: message,
                       target_system: message.target_system,
                       target_component: 0,
                       target: target,
                       crc_extra: crc_extra
                     )}

                  :system_component ->
                    {:ok,
                     struct(frame,
                       message: message,
                       target_system: message.target_system,
                       target_component: message.target_component,
                       target: target,
                       crc_extra: crc_extra
                     )}

                  :component ->
                    {:ok,
                     struct(frame,
                       message: message,
                       target_system: 0,
                       target_component: message.target_component,
                       target: target,
                       crc_extra: crc_extra
                     )}
                end

              _ ->
                :failed_to_unpack
            end
          rescue
            _ ->
              :ok =
                Logger.debug(
                  "validate_and_unpack: Failed to unpack #{inspect(frame)}, couldn't match payload"
                )

              :failed_to_unpack
          end
        else
          :ok = Logger.debug("validate_and_unpack: Checksum invalid #{inspect(frame)}")
          :checksum_invalid
        end

      _ ->
        :ok = Logger.debug("validate_and_unpack: Unknown message #{inspect(frame)}")
        :unknown_message
    end
  end

  @spec signed?(XMAVLink.Frame.t() | non_neg_integer) :: boolean
  def signed?(%XMAVLink.Frame{version: 2, incompatible_flags: incompatible_flags}),
    do: signed?(incompatible_flags)

  def signed?(%XMAVLink.Frame{}), do: false

  def signed?(incompatible_flags) when is_integer(incompatible_flags),
    do: (incompatible_flags &&& @mavlink_2_signature_flag) != 0

  defp unsupported_incompatible_flags?(incompatible_flags),
    do: (incompatible_flags &&& @mavlink_2_supported_incompatible_flags) != incompatible_flags

  defp signed_frame_and_tail(raw_and_rest, frame, rest) do
    case rest do
      <<signature_raw::binary-size(@mavlink_2_signature_length), rest_after_signature::binary>> ->
        {
          struct(frame,
            signature: parse_signature(signature_raw),
            mavlink_2_raw:
              binary_part(
                raw_and_rest,
                0,
                byte_size(raw_and_rest) - byte_size(rest_after_signature)
              )
          ),
          rest_after_signature
        }

      _ ->
        {nil, raw_and_rest}
    end
  end

  defp parse_signature(
         <<link_id::unsigned-integer-size(8), timestamp::little-unsigned-integer-size(48),
           signature::binary-size(6)>>
       ) do
    %XMAVLink.Frame.Signature{
      link_id: link_id,
      timestamp: timestamp,
      signature: signature
    }
  end

  # Pack message frame
  def pack_frame(frame = %XMAVLink.Frame{version: 1}) do
    payload_length = byte_size(frame.payload)

    mavlink_1_frame =
      <<payload_length::unsigned-integer-size(8), frame.sequence_number::unsigned-integer-size(8),
        frame.source_system::unsigned-integer-size(8),
        frame.source_component::unsigned-integer-size(8),
        frame.message_id::little-unsigned-integer-size(8), frame.payload::binary>>

    frame
    |> struct(
      mavlink_1_raw: <<0xFE>> <> mavlink_1_frame <> checksum(mavlink_1_frame, frame.crc_extra)
    )
  end

  def pack_frame(frame = %XMAVLink.Frame{version: 2}) do
    {truncated_length, truncated_payload} = truncate_payload(frame.payload)

    mavlink_2_frame =
      <<
        truncated_length::unsigned-integer-size(8),
        # Incompatible flags
        0::unsigned-integer-size(8),
        # Compatible flags
        0::unsigned-integer-size(8),
        frame.sequence_number::unsigned-integer-size(8),
        frame.source_system::unsigned-integer-size(8),
        frame.source_component::unsigned-integer-size(8),
        frame.message_id::little-unsigned-integer-size(24),
        truncated_payload::binary
      >>

    struct(frame,
      mavlink_2_raw: <<0xFD>> <> mavlink_2_frame <> checksum(mavlink_2_frame, frame.crc_extra)
    )
  end

  # MAVLink 2 truncate trailing 0s in payload
  defp truncate_payload(<<>>), do: {0, <<>>}

  defp truncate_payload(payload) do
    truncated_payload = String.replace_trailing(payload, <<0>>, "")

    if byte_size(truncated_payload) == 0 do
      # First byte of payload never truncated
      {1, <<0>>}
    else
      {byte_size(truncated_payload), truncated_payload}
    end
  end

  # Calculate checksum
  defp checksum(frame, crc_extra) do
    cs = x25_crc(frame <> <<crc_extra::unsigned-integer-size(8)>>)
    <<cs::little-unsigned-integer-size(16)>>
  end

  defp drop_incompatible_signed_frame(raw_and_rest, rest) do
    case rest do
      <<_signature::binary-size(@mavlink_2_signature_length), rest_after_signature::binary>> ->
        {nil, rest_after_signature}

      _ ->
        {nil, raw_and_rest}
    end
  end
end
