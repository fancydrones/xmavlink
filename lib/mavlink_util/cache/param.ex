defmodule XMAVLink.Util.Cache.Param do
  @moduledoc """
  Cached latest MAVLink parameter value with monotonic receive time metadata.
  """

  @enforce_keys [:received_at_ms, :param_id, :message]
  defstruct [:received_at_ms, :param_id, :message]

  @type t :: %__MODULE__{
          received_at_ms: integer,
          param_id: String.t(),
          message: XMAVLink.Message.t()
        }

  @spec new(XMAVLink.Message.t(), integer) :: t
  def new(message = %{param_id: param_id}, received_at_ms) when is_integer(received_at_ms) do
    %__MODULE__{
      received_at_ms: received_at_ms,
      param_id: param_id,
      message: message
    }
  end
end
