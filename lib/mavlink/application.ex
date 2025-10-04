defmodule XMAVLink.Application do
  @moduledoc false

  use Application

  def start(_, _) do
    children = [XMAVLink.Supervisor]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
