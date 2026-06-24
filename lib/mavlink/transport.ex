defmodule XMAVLink.Transport do
  @moduledoc """
  Behaviour for connection transport delegates used by router connection workers.

  Transport modules own external resources such as sockets or UART handles and
  expose pure-ish frame handling helpers to the router.
  """

  @type tokens :: [term]
  @type connection_key :: term
  @type connection :: struct

  @callback open(tokens, pid) ::
              {:ok, connection_key | nil, connection} | {:error, term}
  @callback close(connection) :: term
  @callback forward(connection, XMAVLink.Frame.t()) :: term
end
