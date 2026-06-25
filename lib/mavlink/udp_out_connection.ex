defmodule XMAVLink.UDPOutConnection do
  @moduledoc false

  @behaviour XMAVLink.Transport

  require Logger
  import XMAVLink.Utils, only: [format_address: 1]

  alias XMAVLink.Connection.Inbound
  alias XMAVLink.Connection.Outbound
  alias XMAVLink.ConnectionWorker

  defstruct address: nil,
            port: nil,
            socket: nil,
            worker: nil,
            signing: nil

  @type t :: %XMAVLink.UDPOutConnection{
          address: XMAVLink.Types.net_address(),
          port: XMAVLink.Types.net_port(),
          socket: port,
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
    Inbound.datagram(
      raw,
      receiving_connection,
      socket,
      dialect,
      "UDPOutConnection.handle_info",
      "from #{format_address(source_addr)}:#{source_port}"
    )
  end

  def open(["udpout", address, port], controlling_process) do
    case :gen_udp.open(0, [:binary, active: true] ++ family_options(address)) do
      {:ok, socket} ->
        :ok = Logger.info("Opened udpout:#{format_address(address)}:#{port}")

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

  defp family_options(address) when is_tuple(address) and tuple_size(address) == 8, do: [:inet6]
  defp family_options(_address), do: []

  def close(%XMAVLink.UDPOutConnection{socket: socket}) do
    :gen_udp.close(socket)
  end

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
        frame
      ) do
    :gen_udp.send(socket, address, port, Outbound.packet!(frame))
  end
end
