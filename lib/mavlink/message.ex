defprotocol XMAVLink.Message do
  @spec pack(XMAVLink.Message.t(), 1|2) ::
          {
            :ok, XMAVLink.Types.message_id,
            {
              :ok,
              XMAVLink.Types.crc_extra,
              pos_integer,
              :broadcast | :system | :system_component | :component
            }, binary()} | {:error, String.t}
  def pack(message, version)
end


defimpl XMAVLink.Message, for: [Atom, BitString, Float, Function, Integer, List, Map, PID, Port, Reference, Tuple] do
  def pack(not_a_message, _), do: {:error, "pack(): #{inspect(not_a_message)} is not a MAVLink message"}
end
