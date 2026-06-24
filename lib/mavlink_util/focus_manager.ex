defmodule XMAVLink.Util.FocusManager do
  @moduledoc """
  Manage a protected ETS table representing the nominated MAV focus of
  zero or more local PIDs. The API uses this to streamline iex sessions
  by letting the user select a MAV to work with and transparently adding
  {system_id, component_id} tuples to call arguments.

  Pass `context: context` to read or write focus in a scoped utility table
  namespace.
  """

  use GenServer
  require Logger
  alias XMAVLink.Util.{Context, Tables}

  defstruct monitors: %{},
            sessions: %{},
            context: nil,
            table_prefix: nil,
            tables: Tables.names()

  # API
  def start_link(state, opts \\ []) do
    GenServer.start_link(__MODULE__, state, Keyword.put_new(opts, :name, __MODULE__))
  end

  def focus() do
    self() |> focus()
  end

  def focus(opts) when is_list(opts), do: focus(self(), opts)

  def focus(pid) when is_pid(pid), do: focus(pid, [])

  def focus(system_id) when is_integer(system_id), do: focus(system_id, 1)

  def focus(pid, opts) when is_pid(pid) do
    sessions = Context.new(opts).tables.sessions

    with :ok <- require_table(sessions),
         [{^pid, scid}] <- :ets.lookup(sessions, pid) do
      if pid == self() do
        Logger.info("Vehicle #{format(scid)}")
      else
        Logger.info("Vehicle #{format(scid)} for #{inspect(pid)}")
      end

      {:ok, scid}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        Logger.warning("#{inspect(pid)} has no vehicle focus")
        {:error, :not_focussed}
    end
  end

  def focus(system_id, component_id) when is_integer(system_id) do
    focus(system_id, component_id, [])
  end

  def focus(system_id, component_id, opts)
      when is_integer(system_id) and is_integer(component_id) and is_list(opts) do
    with pid when is_pid(pid) <- GenServer.whereis(__MODULE__),
         {:ok, {system_id, component_id, _}} <-
           GenServer.call(pid, {:focus, {system_id, component_id}, Context.new(opts)}) do
      configure_iex_prompt(system_id, component_id)
    else
      nil -> {:error, :not_started}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    opts = Map.new(opts)
    context = Context.new(opts)

    :ets.new(context.tables.sessions, [:named_table, :protected, {:read_concurrency, true}, :set])

    {:ok,
     struct(
       __MODULE__,
       opts
       |> Map.put(:context, context)
       |> Map.put(:table_prefix, context.table_prefix)
       |> Map.put(:tables, context.tables)
     )}
  end

  @impl true
  def handle_call(
        {:focus, scid = {system_id, component_id}, context},
        {caller_pid, _},
        state
      ) do
    tables = context.tables

    with :ok <- require_table(tables.systems),
         :ok <- require_writable_table(tables.sessions),
         mavlink_major_version when is_number(mavlink_major_version) <-
           :ets.foldl(
             fn {next_scid, %{mavlink_major_version: mmv}}, acc ->
               if next_scid == scid do
                 mmv
               else
                 acc
               end
             end,
             0,
             tables.systems
           ) do
      if mavlink_major_version > 0 do
        state =
          put_focus_session(state, tables, caller_pid, {
            system_id,
            component_id,
            mavlink_major_version
          })

        Logger.info("Set focus to #{format(scid)}")
        {:reply, {:ok, {system_id, component_id, mavlink_major_version}}, state}
      else
        Logger.warning("No such vehicle #{format(scid)}")
        {:reply, {:error, :no_such_mav}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :no_mav_data}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {monitored_pid, monitors} ->
        {session, sessions} = Map.pop(state.sessions, monitored_pid)
        delete_session(session, monitored_pid)

        {:noreply,
         %{
           state
           | monitors: monitors,
             sessions: sessions
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

  defp put_focus_session(state, tables, pid, scid) do
    state = drop_focus_monitor(state, pid)
    ref = Process.monitor(pid)
    :ets.insert(tables.sessions, {pid, scid})

    %{
      state
      | monitors: Map.put(state.monitors, ref, pid),
        sessions: Map.put(state.sessions, pid, {ref, tables.sessions})
    }
  end

  defp drop_focus_monitor(state, pid) do
    case Map.pop(state.sessions, pid) do
      {nil, _sessions} ->
        state

      {{ref, sessions_table}, sessions} ->
        Process.demonitor(ref, [:flush])
        delete_session_table_entry(sessions_table, pid)

        %{
          state
          | monitors: Map.delete(state.monitors, ref),
            sessions: sessions
        }
    end
  end

  defp delete_session(nil, _pid), do: :ok

  defp delete_session({_ref, sessions_table}, pid),
    do: delete_session_table_entry(sessions_table, pid)

  defp delete_session_table_entry(sessions_table, pid) do
    if :ets.info(sessions_table) != :undefined do
      :ets.delete(sessions_table, pid)
    end
  end

  defp format({s, c, _}), do: format({s, c})
  defp format({s, c}), do: "#{s}.#{c}"

  defp require_table(table) do
    case :ets.info(table) do
      :undefined -> {:error, :not_started}
      _ -> :ok
    end
  end

  defp require_writable_table(table) do
    case :ets.info(table) do
      :undefined ->
        {:error, :not_started}

      _ ->
        if :ets.info(table, :owner) == self() or :ets.info(table, :protection) == :public do
          :ok
        else
          {:error, :not_started}
        end
    end
  end
end
