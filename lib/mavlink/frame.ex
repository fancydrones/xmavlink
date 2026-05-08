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
  @mavlink_2_signature_timestamp_max 0xFFFF_FFFF_FFFF

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
          mavlink_1_raw: binary | nil,
          mavlink_2_raw: binary | nil,
          message: message | nil
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

  @spec validate_and_unpack(XMAVLink.Frame.t(), module, XMAVLink.Signing.t() | nil) ::
          {:ok, XMAVLink.Frame.t(), XMAVLink.Signing.t() | nil}
          | {:unknown_message, XMAVLink.Signing.t() | nil}
          | {:error,
             :failed_to_unpack
             | :checksum_invalid
             | :unknown_message
             | XMAVLink.Signing.validate_error(), XMAVLink.Signing.t() | nil}
  def validate_and_unpack(frame, dialect, signing) do
    with {:ok, validated_frame, updated_signing} <-
           XMAVLink.Signing.validate_inbound(frame, signing) do
      case validate_unsigned_and_unpack(validated_frame, dialect) do
        {:ok, valid_frame} -> {:ok, valid_frame, updated_signing}
        :unknown_message -> {:unknown_message, updated_signing}
        reason -> {:error, reason, updated_signing}
      end
    else
      {:error, reason, updated_signing} -> {:error, reason, updated_signing}
    end
  end

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

  @doc """
  Sign an already packed MAVLink 2 frame.

  This is a low-level frame utility. It sets `MAVLINK_IFLAG_SIGNED`,
  recalculates the checksum for the signed header, and appends the 13-byte
  MAVLink 2 signature trailer. It does not manage link timestamp state or
  router/connection signing policy. The existing packed frame checksum must
  already match the frame's `crc_extra`.
  """
  @spec sign_frame(XMAVLink.Frame.t(), <<_::256>>, 0..255, 0..281_474_976_710_655) ::
          {:ok, XMAVLink.Frame.t()}
          | {:error,
             :already_signed
             | :checksum_invalid
             | :invalid_crc_extra
             | :invalid_link_id
             | :invalid_mavlink_2_frame
             | :invalid_secret_key
             | :invalid_timestamp
             | :mavlink_1_not_signable
             | :missing_crc_extra
             | :missing_mavlink_2_raw
             | :unsupported_incompatible_flags}
  def sign_frame(%XMAVLink.Frame{version: 1}, _secret_key, _link_id, _timestamp),
    do: {:error, :mavlink_1_not_signable}

  def sign_frame(frame = %XMAVLink.Frame{version: 2}, secret_key, link_id, timestamp) do
    with :ok <- validate_secret_key(secret_key),
         :ok <- validate_link_id(link_id),
         :ok <- validate_timestamp(timestamp),
         :ok <- validate_crc_extra(frame.crc_extra),
         {:ok, attrs} <- parse_mavlink_2_raw(frame.mavlink_2_raw),
         :ok <- validate_signable_frame_attrs(attrs),
         :ok <- validate_unsigned_checksum(attrs, frame.crc_extra) do
      signature_prefix =
        <<link_id::unsigned-integer-size(8), timestamp::little-unsigned-integer-size(48)>>

      incompatible_flags = attrs.incompatible_flags ||| @mavlink_2_signature_flag

      signed_body = mavlink_2_body(attrs, incompatible_flags)

      checksum = checksum(signed_body, frame.crc_extra)

      signature_hash =
        signature_hash(secret_key, <<0xFD>> <> signed_body <> checksum, signature_prefix)

      signature_raw = signature_prefix <> signature_hash
      signed_raw = <<0xFD>> <> signed_body <> checksum <> signature_raw

      {:ok,
       struct(frame,
         payload_length: attrs.payload_length,
         incompatible_flags: incompatible_flags,
         compatible_flags: attrs.compatible_flags,
         sequence_number: attrs.sequence_number,
         source_system: attrs.source_system,
         source_component: attrs.source_component,
         message_id: attrs.message_id,
         payload: attrs.payload,
         checksum: :binary.decode_unsigned(checksum, :little),
         signature: parse_signature(signature_raw),
         mavlink_2_raw: signed_raw
       )}
    end
  end

  @doc """
  Validate the MAVLink 2 signature trailer for an already parsed signed frame.

  This only verifies the cryptographic signature over the signed packet bytes.
  It does not enforce timestamp replay rules or unpack the frame payload.
  """
  @spec validate_signature(XMAVLink.Frame.t(), <<_::256>>) ::
          :ok
          | {:error,
             :invalid_secret_key
             | :invalid_mavlink_2_frame
             | :signature_invalid
             | :unsigned_frame}
  def validate_signature(frame = %XMAVLink.Frame{version: 2}, secret_key) do
    with :ok <- validate_secret_key(secret_key),
         :ok <- validate_signed_frame(frame),
         {:ok, signed_packet_without_signature, signature} <-
           signed_packet_without_signature(frame.mavlink_2_raw) do
      expected_signature =
        signature_hash(secret_key, signed_packet_without_signature, <<>>)

      if secure_compare(signature, expected_signature) do
        :ok
      else
        {:error, :signature_invalid}
      end
    end
  end

  def validate_signature(%XMAVLink.Frame{}, _secret_key), do: {:error, :unsigned_frame}

  defp unsupported_incompatible_flags?(incompatible_flags),
    do: (incompatible_flags &&& @mavlink_2_supported_incompatible_flags) != incompatible_flags

  defp validate_secret_key(secret_key) when is_binary(secret_key) and byte_size(secret_key) == 32,
    do: :ok

  defp validate_secret_key(_secret_key), do: {:error, :invalid_secret_key}

  defp validate_link_id(link_id) when is_integer(link_id) and link_id in 0..255, do: :ok
  defp validate_link_id(_link_id), do: {:error, :invalid_link_id}

  defp validate_timestamp(timestamp)
       when is_integer(timestamp) and timestamp in 0..@mavlink_2_signature_timestamp_max,
       do: :ok

  defp validate_timestamp(_timestamp), do: {:error, :invalid_timestamp}

  defp validate_crc_extra(nil), do: {:error, :missing_crc_extra}
  defp validate_crc_extra(crc_extra) when is_integer(crc_extra) and crc_extra in 0..255, do: :ok
  defp validate_crc_extra(_crc_extra), do: {:error, :invalid_crc_extra}

  defp parse_mavlink_2_raw(nil), do: {:error, :missing_mavlink_2_raw}

  defp parse_mavlink_2_raw(
         <<0xFD, payload_length::unsigned-integer-size(8),
           incompatible_flags::unsigned-integer-size(8),
           compatible_flags::unsigned-integer-size(8), sequence_number::unsigned-integer-size(8),
           source_system::unsigned-integer-size(8), source_component::unsigned-integer-size(8),
           message_id::little-unsigned-integer-size(24), payload::binary-size(payload_length),
           checksum::little-unsigned-integer-size(16), rest::binary>>
       ) do
    {:ok,
     %{
       payload_length: payload_length,
       incompatible_flags: incompatible_flags,
       compatible_flags: compatible_flags,
       sequence_number: sequence_number,
       source_system: source_system,
       source_component: source_component,
       message_id: message_id,
       payload: payload,
       checksum: checksum,
       rest: rest
     }}
  end

  defp parse_mavlink_2_raw(_raw), do: {:error, :invalid_mavlink_2_frame}

  defp validate_signable_frame_attrs(%{incompatible_flags: incompatible_flags})
       when (incompatible_flags &&& @mavlink_2_signature_flag) != 0,
       do: {:error, :already_signed}

  defp validate_signable_frame_attrs(%{incompatible_flags: incompatible_flags})
       when incompatible_flags != 0,
       do: {:error, :unsupported_incompatible_flags}

  defp validate_signable_frame_attrs(%{rest: <<>>}), do: :ok
  defp validate_signable_frame_attrs(_attrs), do: {:error, :invalid_mavlink_2_frame}

  defp validate_signed_frame(frame = %XMAVLink.Frame{}) do
    if signed?(frame) do
      validate_signed_frame_shape(frame)
    else
      {:error, :unsigned_frame}
    end
  end

  defp validate_signed_frame_shape(%XMAVLink.Frame{signature: nil}), do: {:error, :unsigned_frame}

  defp validate_signed_frame_shape(%XMAVLink.Frame{mavlink_2_raw: mavlink_2_raw})
       when is_binary(mavlink_2_raw) do
    case parse_mavlink_2_raw(mavlink_2_raw) do
      {:ok,
       %{
         incompatible_flags: incompatible_flags,
         rest: <<_signature::binary-size(@mavlink_2_signature_length)>>
       }} ->
        if signed?(incompatible_flags), do: :ok, else: {:error, :invalid_mavlink_2_frame}

      {:ok, _attrs} ->
        {:error, :invalid_mavlink_2_frame}

      error ->
        error
    end
  end

  defp validate_signed_frame_shape(%XMAVLink.Frame{}), do: {:error, :invalid_mavlink_2_frame}

  defp signed_packet_without_signature(raw)
       when is_binary(raw) and byte_size(raw) >= 12 + @mavlink_2_signature_length do
    signed_packet_size = byte_size(raw) - 6

    <<signed_packet_without_signature::binary-size(signed_packet_size),
      signature::binary-size(6)>> = raw

    {:ok, signed_packet_without_signature, signature}
  end

  defp signed_packet_without_signature(_raw), do: {:error, :invalid_mavlink_2_frame}

  defp validate_unsigned_checksum(attrs, crc_extra) do
    if checksum(mavlink_2_body(attrs), crc_extra) ==
         <<attrs.checksum::little-unsigned-integer-size(16)>> do
      :ok
    else
      {:error, :checksum_invalid}
    end
  end

  defp mavlink_2_body(attrs), do: mavlink_2_body(attrs, attrs.incompatible_flags)

  defp mavlink_2_body(attrs, incompatible_flags) do
    <<attrs.payload_length::unsigned-integer-size(8),
      incompatible_flags::unsigned-integer-size(8),
      attrs.compatible_flags::unsigned-integer-size(8),
      attrs.sequence_number::unsigned-integer-size(8),
      attrs.source_system::unsigned-integer-size(8),
      attrs.source_component::unsigned-integer-size(8),
      attrs.message_id::little-unsigned-integer-size(24), attrs.payload::binary>>
  end

  defp signature_hash(secret_key, signed_frame_without_signature, signature_prefix) do
    :crypto.hash(:sha256, secret_key <> signed_frame_without_signature <> signature_prefix)
    |> binary_part(0, 6)
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    if byte_size(left) == byte_size(right) do
      left
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(right))
      |> Enum.reduce(0, fn {left_byte, right_byte}, acc -> acc ||| bxor(left_byte, right_byte) end)
      |> Kernel.==(0)
    else
      false
    end
  end

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
