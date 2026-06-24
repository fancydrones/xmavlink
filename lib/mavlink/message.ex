defprotocol XMAVLink.Message do
  @fallback_to_any true

  @spec pack(XMAVLink.Message.t(), 1 | 2) ::
          {
            :ok,
            XMAVLink.Types.message_id(),
            {
              :ok,
              XMAVLink.Types.crc_extra(),
              pos_integer,
              :broadcast | :system | :system_component | :component
            },
            binary()
          }
          | {:error, String.t()}
  def pack(message, version)
end

defimpl XMAVLink.Message, for: Any do
  def pack(not_a_message = %{__struct__: _}, _) do
    raise Protocol.UndefinedError, protocol: XMAVLink.Message, value: not_a_message
  end

  def pack(not_a_message, _),
    do: {:error, "pack(): #{inspect(not_a_message)} is not a MAVLink message"}
end
