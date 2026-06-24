defmodule XMAVLink.Util.Cache.Message do
  @moduledoc """
  Cached latest MAVLink message with monotonic receive time metadata.
  """

  @enforce_keys [:received_at_ms, :message_type, :message]
  defstruct [:received_at_ms, :message_type, :message]

  @type t :: %__MODULE__{
          received_at_ms: integer,
          message_type: module,
          message: XMAVLink.Message.t()
        }

  @spec new(XMAVLink.Message.t(), integer) :: t
  def new(message = %{__struct__: message_type}, received_at_ms)
      when is_integer(received_at_ms) do
    %__MODULE__{
      received_at_ms: received_at_ms,
      message_type: message_type,
      message: message
    }
  end
end
