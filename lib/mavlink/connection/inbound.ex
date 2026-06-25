defmodule XMAVLink.Connection.Inbound do
  @moduledoc false

  require Logger

  import XMAVLink.Frame, only: [binary_to_frame_and_tail: 1, validate_and_unpack: 3]

  @mavlink_2_signature_flag 0x01
  @mavlink_2_signature_length 13
  @smallest_mavlink_message 8
  @max_stream_buffer_size 4_096

  def datagram(raw, connection, connection_key, dialect, log_prefix, failure_description \\ nil) do
    case binary_to_frame_and_tail(raw) do
      :not_a_frame ->
        Logger.debug("#{log_prefix}: Not a frame #{inspect(raw)}")
        {:error, :not_a_frame, connection_key, connection}

      {nil, _rest} ->
        reason = frame_parse_error(raw)
        Logger.debug("#{log_prefix}: #{parse_error_message(reason)}")
        {:error, reason, connection_key, connection}

      {received_frame, _rest} ->
        validate_frame(
          received_frame,
          connection,
          connection_key,
          dialect,
          log_prefix,
          failure_description
        )
    end
  end

  def stream(raw, connection, buffer, socket, dialect, log_prefix) do
    case binary_to_frame_and_tail(buffer <> raw) do
      :not_a_frame ->
        if byte_size(buffer) + byte_size(raw) > 0 do
          Logger.debug("#{log_prefix}: Not a frame #{inspect(buffer <> raw)}")
        end

        {:error, :not_a_frame, socket, struct(connection, buffer: <<>>)}

      {nil, rest} ->
        if byte_size(rest) > @max_stream_buffer_size do
          Logger.debug(
            "#{log_prefix}: Dropping overlong incomplete MAVLink stream buffer (#{byte_size(rest)} bytes)"
          )

          {:error, :stream_buffer_overflow, socket, struct(connection, buffer: <<>>)}
        else
          {:error, :incomplete_frame, socket, struct(connection, buffer: rest)}
        end

      {received_frame, rest} ->
        if byte_size(rest) >= @smallest_mavlink_message do
          resend_stream_message(socket)
        end

        connection = struct(connection, buffer: rest)
        validate_frame(received_frame, connection, socket, dialect, log_prefix)
    end
  end

  defp validate_frame(
         received_frame,
         connection,
         connection_key,
         dialect,
         log_prefix,
         failure_description \\ nil
       ) do
    case validate_and_unpack(received_frame, dialect, connection.signing) do
      {:ok, valid_frame, signing} ->
        {:ok, connection_key, struct(connection, signing: signing), valid_frame}

      {:unknown_message, signing} ->
        Logger.debug("rebroadcasting unknown message with id #{received_frame.message_id}")

        {:ok, connection_key, struct(connection, signing: signing),
         struct(received_frame, target: :broadcast)}

      {:error, reason, signing} ->
        Logger.debug(
          "#{log_prefix}: frame received#{failure_description(failure_description)} failed: #{Atom.to_string(reason)}"
        )

        {:error, reason, connection_key, struct(connection, signing: signing)}
    end
  end

  defp frame_parse_error(
         raw =
           <<0xFD, payload_length::unsigned-integer-size(8),
             incompatible_flags::unsigned-integer-size(8), _rest::binary>>
       )
       when incompatible_flags != 0 do
    complete_length =
      payload_length + 12 +
        if Bitwise.band(incompatible_flags, @mavlink_2_signature_flag) != 0 do
          @mavlink_2_signature_length
        else
          0
        end

    if byte_size(raw) >= complete_length do
      :incompatible_flags
    else
      :incomplete_frame
    end
  end

  defp frame_parse_error(_raw), do: :incomplete_frame

  defp parse_error_message(:incompatible_flags), do: "Incompatible MAVLink 2 frame"
  defp parse_error_message(:incomplete_frame), do: "Incomplete MAVLink frame"

  defp failure_description(nil), do: ""
  defp failure_description(description), do: " #{description}"

  defp resend_stream_message(socket) when is_port(socket),
    do: send(self(), {:tcp, socket, <<>>})

  defp resend_stream_message(port) when is_binary(port),
    do: send(self(), {:circuits_uart, port, <<>>})
end
