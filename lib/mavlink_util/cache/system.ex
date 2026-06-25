defmodule XMAVLink.Util.Cache.System do
  @moduledoc """
  Cached metadata for one visible MAVLink system/component.
  """

  @enforce_keys [:mavlink_major_version, :mavlink_minor_version]
  defstruct mavlink_major_version: nil,
            mavlink_minor_version: nil,
            param_count: 0,
            param_count_loaded: 0

  @type t :: %__MODULE__{
          mavlink_major_version: XMAVLink.Types.version(),
          mavlink_minor_version: non_neg_integer,
          param_count: non_neg_integer,
          param_count_loaded: non_neg_integer
        }

  @spec new(keyword | map) :: t
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)
end
