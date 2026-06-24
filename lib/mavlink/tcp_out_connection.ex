defmodule XMAVLink.TCPOutConnection do
  @moduledoc """
  MAVLink.Router delegate for TCP connections
  Typically used to connect to SITL on port 5760
  """

  @behaviour XMAVLink.Transport

  require Logger
  alias XMAVLink.Connection.Inbound
  alias XMAVLink.ConnectionWorker
  alias XMAVLink.Frame

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
    Inbound.stream(
      raw,
      receiving_connection,
      buffer,
      socket,
      dialect,
      "TCPOutConnection.handle_info"
    )
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
