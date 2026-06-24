defmodule XMAVLink.Router.Routing do
  @moduledoc false

  alias XMAVLink.Frame
  alias XMAVLink.Router

  @system_time_message_id 2

  @type delivery :: %{
          source_connection: Router.connection_key(),
          recipients: [Router.connection_key()],
          remote_recipients: [Router.connection_key()],
          target: XMAVLink.Dialect.target() | nil,
          message_id: XMAVLink.Types.message_id(),
          unreachable?: boolean
        }

  def update_route_info(
        {:ok, source_connection_key, source_connection,
         frame = %Frame{
           source_system: source_system,
           source_component: source_component
         }},
        state = %Router{}
      ) do
    state = %Router{} = track_system_time(frame, source_connection_key, state)

    {
      :ok,
      source_connection_key,
      frame,
      %Router{
        state
        | routes:
            put_learned_route(
              state.routes,
              source_connection_key,
              source_system,
              source_component
            ),
          connections: Map.put(state.connections, source_connection_key, source_connection)
      }
    }
  end

  def update_route_info(
        {:error, reason, connection_key, connection},
        state = %Router{connections: connections}
      ) do
    {:error, reason,
     %Router{state | connections: Map.put(connections, connection_key, connection)}}
  end

  def remove_connection(
        connection_key,
        state = %Router{connections: connections, routes: routes, connection_workers: workers}
      ) do
    %Router{
      state
      | connections: Map.delete(connections, connection_key),
        connection_workers: Map.delete(workers, connection_key),
        routes:
          routes
          |> Enum.reject(fn {_mavlink_address, route_connection_key} ->
            route_connection_key == connection_key
          end)
          |> Map.new()
    }
  end

  def broadcast_recipients(source_connection_key, %Router{connections: connections} = state) do
    forward_remote? = source_connection_key == :local or state.remote_forwarding

    connections
    |> Enum.flat_map(fn
      {:local, _connection} ->
        [:local]

      {connection_key, _connection}
      when forward_remote? and connection_key != source_connection_key ->
        [connection_key]

      _ ->
        []
    end)
    |> uniq()
  end

  def targeted_recipients(target_system, target_component, source_connection_key, state) do
    target_system
    |> matching_system_components(target_component, state)
    |> Enum.reject(fn key -> key == source_connection_key end)
    |> remote_forwarding_recipients(source_connection_key, state)
    |> uniq()
  end

  def delivery(source_connection_key, recipients, frame, state) do
    remote_recipients = Enum.reject(recipients, &(&1 == :local))

    %{
      source_connection: source_connection_key,
      recipients: recipients,
      remote_recipients: remote_recipients,
      target: frame.target,
      message_id: frame.message_id,
      unreachable?: unreachable?(source_connection_key, recipients, frame, state)
    }
  end

  defp put_learned_route(routes, :local, _source_system, _source_component), do: routes

  defp put_learned_route(routes, source_connection_key, source_system, source_component),
    do: Map.put(routes, {source_system, source_component}, source_connection_key)

  defp track_system_time(_frame, :local, state), do: state

  defp track_system_time(
         %Frame{
           message_id: @system_time_message_id,
           source_system: source_system,
           source_component: source_component,
           message: %{time_boot_ms: time_boot_ms}
         },
         _source_connection_key,
         state = %Router{system_time_boot_ms: system_time_boot_ms}
       )
       when is_integer(time_boot_ms) do
    source = {source_system, source_component}

    state =
      case Map.fetch(system_time_boot_ms, source) do
        {:ok, previous_time_boot_ms} when time_boot_ms < previous_time_boot_ms ->
          clear_system_routes(source_system, state)

        _ ->
          state
      end

    %Router{state | system_time_boot_ms: Map.put(state.system_time_boot_ms, source, time_boot_ms)}
  end

  defp track_system_time(_frame, _source_connection_key, state), do: state

  defp clear_system_routes(source_system, state = %Router{}) do
    %Router{
      state
      | routes: reject_system_keys(state.routes, source_system),
        system_time_boot_ms: reject_system_keys(state.system_time_boot_ms, source_system)
    }
  end

  defp reject_system_keys(map, source_system) do
    map
    |> Enum.reject(fn {{system, _component}, _value} -> system == source_system end)
    |> Map.new()
  end

  defp matching_system_components(q_system, q_component, %Router{routes: routes}) do
    [
      :local
      | routes
        |> Enum.filter(fn {{sid, cid}, _} ->
          (q_system == 0 or q_system == sid) and
            (q_component == 0 or q_component == cid)
        end)
        |> Enum.map(fn {_, ck} -> ck end)
    ]
  end

  defp remote_forwarding_recipients(recipients, :local, _state), do: recipients

  defp remote_forwarding_recipients(recipients, _source_connection_key, %Router{
         remote_forwarding: true
       }),
       do: recipients

  defp remote_forwarding_recipients(recipients, _source_connection_key, %Router{
         remote_forwarding: false
       }),
       do: Enum.filter(recipients, &(&1 == :local))

  defp unreachable?(:local, recipients, %Frame{target: target}, _state) when target != :broadcast,
    do: recipients == [] or recipients == [:local]

  defp unreachable?(_source_connection_key, _recipients, _frame, _state), do: false

  defp uniq(values), do: Enum.uniq(values)
end
