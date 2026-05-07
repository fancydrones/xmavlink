defmodule XMAVLink.Util.FocusManager do
  @moduledoc """
  Manage a protected ETS table representing the nominated MAV focus of
  zero or more local PIDs. The API uses this to streamline iex sessions
  by letting the user select a MAV to work with and transparently adding
  {system_id, component_id} tuples to call arguments.
  """

  use GenServer
  require Logger

  @sessions :sessions
  @systems :systems

  defstruct monitors: %{}, sessions: %{}

  # API
  def start_link(state, opts \\ []) do
    GenServer.start_link(__MODULE__, state, [{:name, __MODULE__} | opts])
  end

  def focus() do
    self() |> focus()
  end

  def focus(pid) when is_pid(pid) do
    with [{^pid, scid}] <- :ets.lookup(@sessions, pid) do
      if pid == self() do
        Logger.info("Vehicle #{format(scid)}")
      else
        Logger.info("Vehicle #{format(scid)} for #{inspect(pid)}")
      end

      {:ok, scid}
    else
      _ ->
        Logger.warning("#{inspect(pid)} has no vehicle focus")
        {:error, :not_focussed}
    end
  end

  def focus(system_id, component_id \\ 1) do
    {:ok, {system_id, component_id, _}} =
      GenServer.call(XMAVLink.Util.FocusManager, {:focus, {system_id, component_id}})

    configure_iex_prompt(system_id, component_id)
  end

  @impl true
  def init(opts) do
    :ets.new(@sessions, [:named_table, :protected, {:read_concurrency, true}, :set])
    {:ok, struct(__MODULE__, opts)}
  end

  @impl true
  def handle_call({:focus, scid = {system_id, component_id}}, {caller_pid, _}, state) do
    with mavlink_major_version when is_number(mavlink_major_version) <-
           :ets.foldl(
             fn {next_scid, %{mavlink_major_version: mmv}}, acc ->
               if next_scid == scid do
                 mmv
               else
                 acc
               end
             end,
             0,
             @systems
           ) do
      if mavlink_major_version > 0 do
        state =
          put_focus_session(state, caller_pid, {system_id, component_id, mavlink_major_version})

        Logger.info("Set focus to #{format(scid)}")
        {:reply, {:ok, {system_id, component_id, mavlink_major_version}}, state}
      else
        Logger.warning("No such vehicle #{format(scid)}")
        {:reply, {:error, :no_such_mav}, state}
      end
    else
      _ -> {:reply, {:error, :no_mav_data}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {monitored_pid, monitors} ->
        :ets.delete(@sessions, monitored_pid)

        {:noreply,
         %{
           state
           | monitors: monitors,
             sessions: Map.delete(state.sessions, monitored_pid)
         }}
    end
  end

  defp configure_iex_prompt(system_id, component_id) do
    if Code.ensure_loaded?(IEx) and function_exported?(IEx, :configure, 1) and
         Process.whereis(IEx.Config) do
      apply(IEx, :configure, [
        [default_prompt: "iex(%counter) vehicle #{system_id}.#{component_id}>"]
      ])
    end

    :ok
  end

  defp put_focus_session(state, pid, scid) do
    state = drop_focus_monitor(state, pid)
    ref = Process.monitor(pid)
    :ets.insert(@sessions, {pid, scid})

    %{
      state
      | monitors: Map.put(state.monitors, ref, pid),
        sessions: Map.put(state.sessions, pid, ref)
    }
  end

  defp drop_focus_monitor(state, pid) do
    case Map.pop(state.sessions, pid) do
      {nil, _sessions} ->
        state

      {ref, sessions} ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | monitors: Map.delete(state.monitors, ref),
            sessions: sessions
        }
    end
  end

  defp format({s, c, _}), do: format({s, c})
  defp format({s, c}), do: "#{s}.#{c}"
end
