defmodule XMAVLink.UDPOutConnection do
  @moduledoc """
  XMAVLink.Router delegate for UDP connections
  """

  require Logger
  import XMAVLink.Frame, only: [binary_to_frame_and_tail: 1, validate_and_unpack: 2]
  alias XMAVLink.Frame

  defstruct address: nil,
            port: nil,
            socket: nil

  @type t :: %XMAVLink.UDPOutConnection{
          address: XMAVLink.Types.net_address(),
          port: XMAVLink.Types.net_port(),
          socket: pid
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

      # UDP sends frame per packet, so ignore rest
      {received_frame, _rest} ->
        case validate_and_unpack(received_frame, dialect) do
          {:ok, valid_frame} ->
            # A udpout connection is single-target, single-socket. Key it by
            # the bare `socket` so update_route_info/2 updates the existing
            # connection entry rather than creating a sibling under
            # `{socket, source_addr, source_port}` — which would cause the
            # broadcast `route/1` clause to forward back out the same UDPOut
            # (echo) when the reply's source IP differs from the configured
            # target (NAT / masquerade / kube-proxy DNAT).
            {:ok, socket, receiving_connection, valid_frame}

          :unknown_message ->
            # We re-broadcast valid frames with unknown messages
            :ok = Logger.debug("relaying unknown message with id #{received_frame.message_id}}")

            {:ok, socket, receiving_connection, struct(received_frame, target: :broadcast)}

          reason ->
            :ok =
              Logger.debug(
                "UDPOutConnection.handle_info: frame received from " <>
                  "#{Enum.join(Tuple.to_list(source_addr), ".")}:#{source_port} failed: #{Atom.to_string(reason)}"
              )

            {:error, reason, socket, receiving_connection}
        end
    end
  end

  def connect(["udpout", address, port], controlling_process) do
    case :gen_udp.open(0, [:binary, active: true]) do
      {:ok, socket} ->
        :ok = Logger.info("Opened udpout:#{Enum.join(Tuple.to_list(address), ".")}:#{port}")

        send(
          controlling_process,
          {
            :add_connection,
            socket,
            struct(
              XMAVLink.UDPOutConnection,
              socket: socket,
              address: address,
              port: port
            )
          }
        )

        :gen_udp.controlling_process(socket, controlling_process)

      other ->
        :ok =
          Logger.debug(
            "Could not open udpout:#{Enum.join(Tuple.to_list(address), ".")}:#{port}: #{inspect(other)}. Retrying in 1 second"
          )

        :timer.sleep(1000)
        connect(["udpout", address, port], controlling_process)
    end
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
