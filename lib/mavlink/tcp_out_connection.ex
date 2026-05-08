defmodule XMAVLink.TCPOutConnection do
  @moduledoc """
  MAVLink.Router delegate for TCP connections
  Typically used to connect to SITL on port 5760
  """

  @smallest_mavlink_message 8

  require Logger
  alias XMAVLink.ConnectionWorker
  alias XMAVLink.Frame

  import XMAVLink.Frame, only: [binary_to_frame_and_tail: 1, validate_and_unpack: 3]

  defstruct socket: nil, address: nil, port: nil, buffer: <<>>, worker: nil, signing: nil

  @type t :: %XMAVLink.TCPOutConnection{
          socket: pid,
          address: XMAVLink.Types.net_address(),
          port: XMAVLink.Types.net_port(),
          buffer: binary,
          worker: pid | nil,
          signing: XMAVLink.Signing.t() | nil
        }

  def handle_info(
        {:tcp, socket, raw},
        receiving_connection = %XMAVLink.TCPOutConnection{buffer: buffer},
        dialect
      ) do
    case binary_to_frame_and_tail(buffer <> raw) do
      :not_a_frame ->
        # Noise or malformed frame
        if byte_size(buffer) + byte_size(raw) > 0 do
          :ok =
            Logger.debug("TCPOutConnection.handle_info: Not a frame #{inspect(buffer <> raw)}")
        end

        {:error, :not_a_frame, socket, struct(receiving_connection, buffer: <<>>)}

      {nil, rest} ->
        {:error, :incomplete_frame, socket, struct(receiving_connection, buffer: rest)}

      {received_frame, rest} ->
        # Rest could be a message, return later to try emptying the buffer
        if byte_size(rest) >= @smallest_mavlink_message, do: send(self(), {:tcp, socket, <<>>})

        connection = struct(receiving_connection, buffer: rest)

        case validate_and_unpack(received_frame, dialect, receiving_connection.signing) do
          {:ok, valid_frame, signing} ->
            {:ok, socket, struct(connection, signing: signing), valid_frame}

          {:unknown_message, signing} ->
            # We re-broadcast valid frames with unknown messages
            :ok =
              Logger.debug("rebroadcasting unknown message with id #{received_frame.message_id}")

            {:ok, socket, struct(connection, signing: signing),
             struct(received_frame, target: :broadcast)}

          {:error, reason, signing} ->
            :ok =
              Logger.debug(
                "TCPOutConnection.handle_info: frame received failed: #{Atom.to_string(reason)}"
              )

            {:error, reason, socket, struct(connection, signing: signing)}
        end
    end
  end

  def open(["tcpout", address, port], controlling_process) do
    case :gen_tcp.connect(address, port, [:binary, active: true]) do
      {:ok, socket} ->
        :ok = Logger.debug("Opened tcpout:#{Enum.join(Tuple.to_list(address), ".")}:#{port}")

        :ok = :gen_tcp.controlling_process(socket, controlling_process)

        {:ok, socket,
         struct(
           XMAVLink.TCPOutConnection,
           socket: socket,
           address: address,
           port: port,
           worker: controlling_process
         )}

      other ->
        {:error, other}
    end
  end

  def close(%XMAVLink.TCPOutConnection{socket: socket}) do
    :gen_tcp.close(socket)
  end

  def forward(
        connection = %XMAVLink.TCPOutConnection{worker: worker},
        frame
      )
      when is_pid(worker) do
    ConnectionWorker.forward(worker, connection, frame)
  end

  def forward(
        %XMAVLink.TCPOutConnection{socket: socket},
        %Frame{version: 1, mavlink_1_raw: packet}
      ) do
    :gen_tcp.send(socket, packet)
  end

  def forward(
        %XMAVLink.TCPOutConnection{socket: socket},
        %Frame{version: 2, mavlink_2_raw: packet}
      ) do
    :gen_tcp.send(socket, packet)
  end
end
