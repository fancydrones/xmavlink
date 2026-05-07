defmodule XMAVLink.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(_) do
    Supervisor.start_link(__MODULE__, [], name: :"XMAVLink.Supervisor")
  end

  @impl true
  def init(_) do
    router_name = Application.get_env(:xmavlink, :router_name, XMAVLink.Router) || XMAVLink.Router

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
            name: router_name,
            dialect: Application.get_env(:xmavlink, :dialect),
            system: Application.get_env(:xmavlink, :system_id),
            component: Application.get_env(:xmavlink, :component_id),
            connection_strings: Application.get_env(:xmavlink, :connections),
            connection_retry_ms: Application.get_env(:xmavlink, :connection_retry_ms, 1_000)
          }
        }
      ] ++ heartbeat_child_specs(router_name)

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp heartbeat_child_specs(router_name) do
    specs = heartbeat_specs()
    multi? = length(specs) > 1

    specs
    |> Enum.with_index()
    |> Enum.map(fn {spec, index} ->
      child_spec =
        spec
        |> Keyword.put_new(:router, router_name)
        |> maybe_unnamed_heartbeat(multi?)

      %{
        id: Keyword.get(spec, :id, {XMAVLink.Heartbeat, index}),
        start: {XMAVLink.Heartbeat, :start_link, [child_spec]}
      }
    end)
  end

  defp maybe_unnamed_heartbeat(spec, true), do: Keyword.put_new(spec, :name, nil)
  defp maybe_unnamed_heartbeat(spec, false), do: spec

  # Heartbeats are started only when configured, so existing apps that
  # build their own heartbeats keep working unchanged. `:heartbeat` keeps
  # the original single-emitter contract; `:heartbeats` allows multiple
  # local source identities to share one router.
  defp heartbeat_specs do
    legacy =
      case Application.get_env(:xmavlink, :heartbeat) do
        nil -> []
        spec -> [spec]
      end

    legacy ++ (Application.get_env(:xmavlink, :heartbeats) || [])
  end
end
