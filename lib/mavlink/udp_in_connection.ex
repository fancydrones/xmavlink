defmodule XMAVLink.UDPInConnection do
  @moduledoc """
  MXAVLink.Router delegate for UDP connections
  """

  require Logger
  import XMAVLink.Frame, only: [binary_to_frame_and_tail: 1, validate_and_unpack: 2]

  alias XMAVLink.ConnectionWorker
  alias XMAVLink.Frame

  defstruct address: nil,
            port: nil,
            socket: nil,
            worker: nil

  @type t :: %XMAVLink.UDPInConnection{
          address: XMAVLink.Types.net_address(),
          port: XMAVLink.Types.net_port(),
          socket: pid,
          worker: pid | nil
        }

  # Create connection if this is the first time we've received on it
  def handle_info({:udp, socket, source_addr, source_port, raw}, nil, dialect) do
    handle_info(
      {:udp, socket, source_addr, source_port, raw},
      %XMAVLink.UDPInConnection{address: source_addr, port: source_port, socket: socket},
      dialect
    )
  end

  def handle_info({:udp, socket, source_addr, source_port, raw}, receiving_connection, dialect) do
    case binary_to_frame_and_tail(raw) do
      :not_a_frame ->
        # Noise or malformed frame
        :ok = Logger.debug("UDPInConnection.handle_info: Not a frame #{inspect(raw)}")
        {:error, :not_a_frame, {socket, source_addr, source_port}, receiving_connection}

      {nil, _rest} ->
        # MAVLink 2 frames with incompatible flags are intentionally unsupported.
        :ok = Logger.debug("UDPInConnection.handle_info: Incompatible MAVLink 2 frame")
        {:error, :incompatible_flags, {socket, source_addr, source_port}, receiving_connection}

      # UDP sends frame per packet, so ignore rest
      {received_frame, _rest} ->
        case validate_and_unpack(received_frame, dialect) do
          {:ok, valid_frame} ->
            # Include address and port in connection key because multiple
            # clients can connect to a UDP "in" port.
            {:ok, {socket, source_addr, source_port}, receiving_connection, valid_frame}

          :unknown_message ->
            # We re-broadcast valid frames with unknown messages
            :ok =
              Logger.debug("rebroadcasting unknown message with id #{received_frame.message_id}}")

            {:ok, {socket, source_addr, source_port}, receiving_connection,
             struct(received_frame, target: :broadcast)}

          reason ->
            :ok =
              Logger.debug(
                "UDPInConnection.handle_info: frame received from " <>
                  "#{Enum.join(Tuple.to_list(source_addr), ".")}:#{source_port} failed: #{Atom.to_string(reason)}"
              )

            {:error, reason, {socket, source_addr, source_port}, receiving_connection}
        end
    end
  end

  def handle_info({:udp, socket, source_addr, source_port, raw}, nil, dialect, worker) do
    handle_info(
      {:udp, socket, source_addr, source_port, raw},
      %XMAVLink.UDPInConnection{
        address: source_addr,
        port: source_port,
        socket: socket,
        worker: worker
      },
      dialect
    )
  end

  def handle_info(message, receiving_connection, dialect, _worker) do
    handle_info(message, receiving_connection, dialect)
  end

  def open(["udpin", address, port], controlling_process) do
    # Do not add to connections, we don't want to forward to ourselves
    # Router.update_route_info() will add connections for other parties that
    # connect to this socket
    case :gen_udp.open(port, [:binary, ip: address, active: true]) do
      {:ok, socket} ->
        :ok = Logger.info("Opened udpin:#{Enum.join(Tuple.to_list(address), ".")}:#{port}")
        :ok = :gen_udp.controlling_process(socket, controlling_process)

        {:ok, nil,
         struct(
           XMAVLink.UDPInConnection,
           socket: socket,
           address: address,
           port: port,
           worker: controlling_process
         )}

      other ->
        {:error, other}
    end
  end

  def close(%XMAVLink.UDPInConnection{socket: socket}) do
    :gen_udp.close(socket)
  end

  def forward(
        connection = %XMAVLink.UDPInConnection{
          worker: worker
        },
        frame
      )
      when is_pid(worker) do
    ConnectionWorker.forward(worker, connection, frame)
  end

  def forward(
        %XMAVLink.UDPInConnection{
          socket: socket,
          address: address,
          port: port
        },
        %Frame{version: 1, mavlink_1_raw: packet}
      ) do
    :gen_udp.send(socket, address, port, packet)
  end

  def forward(
        %XMAVLink.UDPInConnection{
          socket: socket,
          address: address,
          port: port
        },
        %Frame{version: 2, mavlink_2_raw: packet}
      ) do
    :gen_udp.send(socket, address, port, packet)
  end
end
