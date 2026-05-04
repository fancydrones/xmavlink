defmodule XMAVLink.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(_) do
    Supervisor.start_link(__MODULE__, [], name: :"XMAVLink.Supervisor")
  end

  @impl true
  def init(_) do
    children =
      [
        :poolboy.child_spec(
          :worker,
          name: {:local, XMAVLink.UARTPool},
          worker_module: Circuits.UART,
          size: 0,
          # How many serial ports might you need?
          max_overflow: 10
        ),
        {
          XMAVLink.Router,
          %{
            dialect: Application.get_env(:xmavlink, :dialect),
            system: Application.get_env(:xmavlink, :system_id),
            component: Application.get_env(:xmavlink, :component_id),
            connection_strings: Application.get_env(:xmavlink, :connections)
          }
        }
      ] ++ heartbeat_child_specs()

    Supervisor.init(children, strategy: :one_for_all)
  end

  # Heartbeat is started only when configured, so existing apps that
  # build their own heartbeats keep working unchanged.
  defp heartbeat_child_specs do
    case Application.get_env(:xmavlink, :heartbeat) do
      nil -> []
      spec -> [{XMAVLink.Heartbeat, spec}]
    end
  end
end
