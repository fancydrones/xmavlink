defmodule XMAVLink.Util.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    router = Keyword.get(opts, :router, XMAVLink.Router)

    children = [
      {XMAVLink.Util.FocusManager, %{}},
      {XMAVLink.Util.CacheManager, %{router: router}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
