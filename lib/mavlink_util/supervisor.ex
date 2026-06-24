defmodule XMAVLink.Util.Supervisor do
  @moduledoc false

  use Supervisor
  alias XMAVLink.Util.Context

  def start_link(opts) do
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
