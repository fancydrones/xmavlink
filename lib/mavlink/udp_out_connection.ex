defmodule XMAVLink.UDPOutConnection do
  @moduledoc """
  XMAVLink.Router delegate for UDP connections
  """

  require Logger
  import XMAVLink.Frame, only: [binary_to_frame_and_tail: 1, validate_and_unpack: 3]
  alias XMAVLink.ConnectionWorker
  alias XMAVLink.Frame

  @mavlink_2_signature_flag 0x01
  @mavlink_2_signature_length 13

  defstruct address: nil,
            port: nil,
            socket: nil,
            worker: nil,
            signing: nil

  @type t :: %XMAVLink.UDPOutConnection{
          address: XMAVLink.Types.net_address(),
          port: XMAVLink.Types.net_port(),
          socket: pid,
          worker: pid | nil,
          signing: XMAVLink.Signing.t() | nil
        }

  # Create connection if this is the first time we've received on it
  def handle_info({:udp, socket, source_addr, source_port, raw}, nil, dialect) do
    handle_info(
      {:udp, socket, source_addr, source_port, raw},
      %XMAVLink.UDPOutConnection{address: source_addr, port: source_port, socket: socket},
      dialect
    )
  end

  def handle_info({:udp, socket, source_addr, source_port, raw}, receiving_connection, dialect) do
    case binary_to_frame_and_tail(raw) do
      :not_a_frame ->
        # Noise or malformed frame
        :ok = Logger.debug("UDPOutConnection.handle_info: Not a frame #{inspect(raw)}")
        {:error, :not_a_frame, socket, receiving_connection}

      {nil, _rest} ->
        reason = frame_parse_error(raw)
        :ok = Logger.debug("UDPOutConnection.handle_info: #{parse_error_message(reason)}")
        {:error, reason, socket, receiving_connection}

      # UDP sends frame per packet, so ignore rest
      {received_frame, _rest} ->
        case validate_and_unpack(received_frame, dialect, receiving_connection.signing) do
          {:ok, valid_frame, signing} ->
            # A udpout connection is single-target, single-socket. Key it by
            # the bare `socket` so update_route_info/2 updates the existing
            # connection entry rather than creating a sibling under
            # `{socket, source_addr, source_port}` — which would cause the
            # broadcast `route/1` clause to forward back out the same UDPOut
            # (echo) when the reply's source IP differs from the configured
            # target (NAT / masquerade / kube-proxy DNAT).
            {:ok, socket, struct(receiving_connection, signing: signing), valid_frame}

          {:unknown_message, signing} ->
            # We re-broadcast valid frames with unknown messages
            :ok = Logger.debug("relaying unknown message with id #{received_frame.message_id}}")

            {:ok, socket, struct(receiving_connection, signing: signing),
             struct(received_frame, target: :broadcast)}

          {:error, reason, signing} ->
            :ok =
              Logger.debug(
                "UDPOutConnection.handle_info: frame received from " <>
                  "#{Enum.join(Tuple.to_list(source_addr), ".")}:#{source_port} failed: #{Atom.to_string(reason)}"
              )

            {:error, reason, socket, struct(receiving_connection, signing: signing)}
        end
    end
  end

  def open(["udpout", address, port], controlling_process) do
    case :gen_udp.open(0, [:binary, active: true]) do
      {:ok, socket} ->
        :ok = Logger.info("Opened udpout:#{Enum.join(Tuple.to_list(address), ".")}:#{port}")

        :ok = :gen_udp.controlling_process(socket, controlling_process)

        {:ok, socket,
         struct(
           XMAVLink.UDPOutConnection,
           socket: socket,
           address: address,
           port: port,
           worker: controlling_process
         )}

      other ->
        {:error, other}
    end
  end

  def close(%XMAVLink.UDPOutConnection{socket: socket}) do
    :gen_udp.close(socket)
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

  def forward(
        connection = %XMAVLink.UDPOutConnection{
          worker: worker
        },
        frame
      )
      when is_pid(worker) do
    ConnectionWorker.forward(worker, connection, frame)
  end

  def forward(
        %XMAVLink.UDPOutConnection{
          socket: socket,
          address: address,
          port: port
        },
        %Frame{version: 1, mavlink_1_raw: packet}
      ) do
    :gen_udp.send(socket, address, port, packet)
  end

  def forward(
        %XMAVLink.UDPOutConnection{
          socket: socket,
          address: address,
          port: port
        },
        %Frame{version: 2, mavlink_2_raw: packet}
      ) do
    :gen_udp.send(socket, address, port, packet)
  end
end
