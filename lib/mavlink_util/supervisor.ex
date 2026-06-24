defmodule XMAVLink.Util.Supervisor do
  @moduledoc """
  Supervisor for opt-in utility processes.

  Start this supervisor when an application wants `XMAVLink.Util.CacheManager`
  and `XMAVLink.Util.FocusManager` for a router. Pass `:context` to scope the
  utility runtime, or pass `:router`, `:dialect`, and `:table_prefix` options
  that can be normalized by `XMAVLink.Util.Context`.
  """

  use Supervisor
  alias XMAVLink.Util.Context

  @spec start_link(keyword) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    context = Context.new(opts)
    auto_param_request = Keyword.get(opts, :auto_param_request, true)

    children = [
      {XMAVLink.Util.FocusManager, %{context: context}},
      {XMAVLink.Util.CacheManager,
       %{
         context: context,
         auto_param_request: auto_param_request
       }}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
