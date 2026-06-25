defmodule XMAVLink.TCPOutConnection do
  @moduledoc false

  @behaviour XMAVLink.Transport

  require Logger
  import XMAVLink.Utils, only: [format_address: 1]

  alias XMAVLink.Connection.Inbound
  alias XMAVLink.Connection.Outbound
  alias XMAVLink.ConnectionWorker

  defstruct socket: nil, address: nil, port: nil, buffer: <<>>, worker: nil, signing: nil

  @type t :: %XMAVLink.TCPOutConnection{
          socket: port,
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
    case :gen_tcp.connect(address, port, [:binary, active: true] ++ family_options(address)) do
      {:ok, socket} ->
        :ok = Logger.debug("Opened tcpout:#{format_address(address)}:#{port}")

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

  defp family_options(address) when is_tuple(address) and tuple_size(address) == 8, do: [:inet6]
  defp family_options(_address), do: []

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
        frame
      ) do
    :gen_tcp.send(socket, Outbound.packet!(frame))
  end
end
