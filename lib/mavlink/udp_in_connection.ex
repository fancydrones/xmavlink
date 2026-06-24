defmodule XMAVLink.UDPInConnection do
  @moduledoc """
  MXAVLink.Router delegate for UDP connections
  """

  @behaviour XMAVLink.Transport

  require Logger

  alias XMAVLink.Connection.Inbound
  alias XMAVLink.ConnectionWorker
  alias XMAVLink.Frame

  defstruct address: nil,
            port: nil,
            socket: nil,
            worker: nil,
            signing: nil

  @type t :: %XMAVLink.UDPInConnection{
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
      %XMAVLink.UDPInConnection{address: source_addr, port: source_port, socket: socket},
      dialect
    )
  end

  def handle_info({:udp, socket, source_addr, source_port, raw}, receiving_connection, dialect) do
    connection_key = {socket, source_addr, source_port}

    Inbound.datagram(
      raw,
      receiving_connection,
      connection_key,
      dialect,
      "UDPInConnection.handle_info",
      "from #{Enum.join(Tuple.to_list(source_addr), ".")}:#{source_port}"
    )
  end

  def handle_info({:udp, socket, source_addr, source_port, raw}, nil, dialect, worker) do
    handle_info({:udp, socket, source_addr, source_port, raw}, nil, dialect, worker, nil)
  end

  def handle_info(message, receiving_connection, dialect, _worker) do
    handle_info(message, receiving_connection, dialect)
  end

  def handle_info({:udp, socket, source_addr, source_port, raw}, nil, dialect, worker, signing) do
    handle_info(
      {:udp, socket, source_addr, source_port, raw},
      %XMAVLink.UDPInConnection{
        address: source_addr,
        port: source_port,
        socket: socket,
        worker: worker,
        signing: signing
      },
      dialect
    )
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
