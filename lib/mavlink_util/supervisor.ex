defmodule XMAVLink.Util.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(_) do
    Supervisor.start_link(__MODULE__, [], name: :"MAVLink.Util.Supervisor")
  end

  @impl true
  def init(_) do
    children = [
      {XMAVLink.Util.CacheManager, %{}},
      {XMAVLink.Util.FocusManager, %{}}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
