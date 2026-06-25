defmodule XMAVLink.Connection.Outbound do
  @moduledoc false

  alias XMAVLink.Frame

  def packet!(%Frame{version: 1, mavlink_1_raw: packet}) when is_binary(packet), do: packet
  def packet!(%Frame{version: 2, mavlink_2_raw: packet}) when is_binary(packet), do: packet
end
