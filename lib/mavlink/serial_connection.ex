defmodule XMAVLink.SerialConnection do
  @moduledoc false

  @behaviour XMAVLink.Transport

  require Logger

  alias XMAVLink.Connection.Inbound
  alias XMAVLink.Connection.Outbound
  alias XMAVLink.ConnectionWorker
  alias Circuits.UART

  defstruct port: nil,
            baud: nil,
            uart: nil,
            buffer: <<>>,
            worker: nil,
            signing: nil

  @type t :: %XMAVLink.SerialConnection{
          port: binary,
          baud: non_neg_integer,
          uart: pid,
          buffer: binary,
          worker: pid | nil,
          signing: XMAVLink.Signing.t() | nil
        }

  def handle_info(
        {:circuits_uart, port, raw},
        receiving_connection = %XMAVLink.SerialConnection{buffer: buffer},
        dialect
      ) do
    Inbound.stream(
      raw,
      receiving_connection,
      buffer,
      port,
      dialect,
      "SerialConnection.handle_info"
    )
  end

  def open(["serial", port, baud], controlling_process) do
    if Map.has_key?(UART.enumerate(), port) do
      uart = :poolboy.checkout(XMAVLink.UARTPool)

      case UART.open(uart, port, speed: baud, active: true) do
        :ok ->
          :ok = Logger.info("Opened serial port #{port} at #{baud} baud")

          :ok = UART.controlling_process(uart, controlling_process)

          {:ok, port,
           struct(
             XMAVLink.SerialConnection,
             port: port,
             baud: baud,
             uart: uart,
             worker: controlling_process
           )}

        {:error, reason} ->
          :poolboy.checkin(XMAVLink.UARTPool, uart)
          {:error, {:open_failed, reason}}
      end
    else
      {:error, :not_attached}
    end
  end

  def close(%XMAVLink.SerialConnection{uart: uart}) do
    _ = UART.close(uart)
    :poolboy.checkin(XMAVLink.UARTPool, uart)
  end

  def forward(
        connection = %XMAVLink.SerialConnection{worker: worker},
        frame
      )
      when is_pid(worker) do
    ConnectionWorker.forward(worker, connection, frame)
  end

  def forward(
        %XMAVLink.SerialConnection{uart: uart},
        frame
      ) do
    UART.write(uart, Outbound.packet!(frame))
  end
end
