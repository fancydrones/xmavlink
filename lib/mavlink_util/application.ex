defmodule XMAVLink.Util.Application do
  @moduledoc false

  use Application

  def start(_, _) do
    router_name = Application.get_env(:xmavlink, :router_name, XMAVLink.Router) || XMAVLink.Router
    children = [{XMAVLink.Util.Supervisor, router: router_name}]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
