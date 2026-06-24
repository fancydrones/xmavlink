defmodule XMAVLink.Dialect do
  @moduledoc """
  Behaviour implemented by generated MAVLink dialect modules.

  The generator already emits these functions for each dialect. This behaviour
  makes the runtime contract explicit without changing generated module names
  or message structs.
  """

  @type target :: :broadcast | :system | :system_component | :component

  @callback mavlink_version() :: non_neg_integer
  @callback mavlink_dialect() :: non_neg_integer
  @callback describe(atom) :: String.t()
  @callback describe_params(atom) :: XMAVLink.Types.param_description_list()
  @callback encode(atom | integer, atom) :: integer
  @callback decode(integer, atom) :: atom | integer
  @callback msg_attributes(XMAVLink.Types.message_id()) ::
              {:ok, XMAVLink.Types.crc_extra(), pos_integer, target}
              | {:error, :unknown_message_id}
  @callback unpack(XMAVLink.Types.message_id(), XMAVLink.Types.version(), binary) ::
              {:ok, XMAVLink.Message.t()} | {:error, :unknown_message}
end
