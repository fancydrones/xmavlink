defmodule XMAVLink.Transport do
  @moduledoc false

  @type tokens :: [term]
  @type connection_key :: term
  @type connection :: struct

  @callback open(tokens, pid) ::
              {:ok, connection_key | nil, connection} | {:error, term}
  @callback close(connection) :: term
  @callback forward(connection, XMAVLink.Frame.t()) :: term
end
