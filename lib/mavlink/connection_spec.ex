defmodule XMAVLink.ConnectionSpec do
  @moduledoc false

  import XMAVLink.Utils, only: [parse_positive_integer: 1, resolve_address: 1]

  alias XMAVLink.SerialConnection
  alias XMAVLink.TCPOutConnection
  alias XMAVLink.UDPInConnection
  alias XMAVLink.UDPOutConnection

  @type t :: %{
          required(:transport) => module,
          required(:tokens) => [term]
        }

  @spec parse(String.t()) :: t
  def parse(connection_string) when is_binary(connection_string),
    do: connection_string |> String.split([":", ","]) |> parse_tokens()

  defp parse_tokens(tokens = ["udpin" | _]),
    do: %{transport: UDPInConnection, tokens: validate_address_and_port(tokens)}

  defp parse_tokens(tokens = ["udpout" | _]),
    do: %{transport: UDPOutConnection, tokens: validate_address_and_port(tokens)}

  defp parse_tokens(tokens = ["tcpout" | _]),
    do: %{transport: TCPOutConnection, tokens: validate_address_and_port(tokens)}

  defp parse_tokens(tokens = ["serial" | _]),
    do: %{transport: SerialConnection, tokens: validate_port_and_baud(tokens)}

  defp parse_tokens([invalid_protocol | _]),
    do: raise(ArgumentError, message: "invalid protocol #{invalid_protocol}")

  defp validate_address_and_port([protocol, address, port]) do
    case {resolve_address(address), parse_positive_integer(port)} do
      {{:error, reason}, _} ->
        raise ArgumentError,
          message: "invalid address #{address}: #{inspect(reason)}"

      {_, :error} ->
        raise ArgumentError, message: "invalid port #{port}"

      {{:ok, parsed_address}, parsed_port} ->
        [protocol, parsed_address, parsed_port]
    end
  end

  defp validate_address_and_port([protocol | _]),
    do: raise(ArgumentError, message: "invalid #{protocol} connection string")

  defp validate_port_and_baud(["serial", port, baud]) do
    case {is_binary(port), parse_positive_integer(baud)} do
      {false, _} ->
        raise ArgumentError, message: "Invalid port #{port}"

      {_, :error} ->
        raise ArgumentError, message: "invalid baud rate #{baud}"

      {true, parsed_baud} ->
        ["serial", port, parsed_baud]
    end
  end

  defp validate_port_and_baud(["serial" | _]),
    do: raise(ArgumentError, message: "invalid serial connection string")
end
