defmodule XMAVLink.Router.ConnectionRegistry do
  @moduledoc false

  alias XMAVLink.Router
  alias XMAVLink.Router.Routing

  def with_signing(connection, signing) do
    if Map.has_key?(connection, :signing) do
      struct(connection, signing: signing)
    else
      connection
    end
  end

  def monitor_worker(state, worker) do
    if worker in Map.values(state.connection_worker_monitors) do
      state
    else
      ref = Process.monitor(worker)
      put_in(state.connection_worker_monitors[ref], worker)
    end
  end

  def track_worker(state, connection_key, %{worker: worker}) when is_pid(worker) do
    state
    |> monitor_worker(worker)
    |> struct(connection_workers: Map.put(state.connection_workers, connection_key, worker))
  end

  def track_worker(state, _connection_key, _connection), do: state

  def track_workers(state) do
    Enum.reduce(state.connections, state, fn {connection_key, connection}, updated_state ->
      track_worker(updated_state, connection_key, connection)
    end)
  end

  def remove_worker_connection(connection_key, worker, state) do
    if state.connection_workers[connection_key] == worker do
      remove_connection(connection_key, state)
    else
      state
    end
  end

  def remove_connections_for_worker(state, worker) do
    state.connection_workers
    |> Enum.filter(fn {_connection_key, connection_worker} -> connection_worker == worker end)
    |> Enum.reduce(state, fn {connection_key, _worker}, updated_state ->
      remove_connection(connection_key, updated_state)
    end)
  end

  def remove_connection(connection_key, state = %Router{}) do
    Routing.remove_connection(connection_key, state)
  end
end
