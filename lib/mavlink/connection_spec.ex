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
    do: connection_string |> parse_connection_string() |> parse_tokens()

  defp parse_connection_string(connection_string) do
    cond do
      network_uri?(connection_string) ->
        parse_network_uri(connection_string)

      bracketed_network_string?(connection_string) ->
        parse_bracketed_network_string(connection_string)

      String.starts_with?(connection_string, "serial:") ->
        parse_serial_string(connection_string)

      true ->
        String.split(connection_string, [":", ","])
    end
  end

  defp network_uri?(connection_string) do
    String.match?(connection_string, ~r/\A(?:udpin|udpout|tcpout):\/\//)
  end

  defp parse_network_uri(connection_string) do
    case URI.parse(connection_string) do
      %URI{scheme: protocol, host: host, port: port}
      when protocol in ["udpin", "udpout", "tcpout"] and is_binary(host) and is_integer(port) ->
        [protocol, host, Integer.to_string(port)]

      %URI{scheme: protocol} when protocol in ["udpin", "udpout", "tcpout"] ->
        [protocol]

      %URI{scheme: protocol} ->
        [protocol || connection_string]
    end
  end

  defp bracketed_network_string?(connection_string) do
    String.match?(connection_string, ~r/\A(?:udpin|udpout|tcpout):\[[^\]]+\]:[^:]+\z/)
  end

  defp parse_bracketed_network_string(connection_string) do
    [protocol, rest] = String.split(connection_string, ":[", parts: 2)
    [address, port] = String.split(rest, "]:", parts: 2)
    [protocol, address, port]
  end

  defp parse_serial_string(connection_string) do
    case String.split(connection_string, ":", parts: 3) do
      ["serial", port, baud] -> ["serial", port, baud]
      ["serial" | rest] -> ["serial" | rest]
    end
  end

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
    case parse_positive_integer(baud) do
      :error ->
        raise ArgumentError, message: "invalid baud rate #{baud}"

      parsed_baud ->
        ["serial", port, parsed_baud]
    end
  end

  defp validate_port_and_baud(["serial" | _]),
    do: raise(ArgumentError, message: "invalid serial connection string")
end
