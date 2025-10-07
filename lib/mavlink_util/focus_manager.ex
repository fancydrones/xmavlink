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

    # Only works for single IEx session
    IEx.configure(default_prompt: "iex(%counter) vehicle #{system_id}.#{component_id}>")
  end

  @impl true
  def init(_opts) do
    :ets.new(@sessions, [:named_table, :protected, {:read_concurrency, true}, :set])
    {:ok, %{}}
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
        :ets.insert(@sessions, {caller_pid, {system_id, component_id, mavlink_major_version}})
        Process.monitor(caller_pid)
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

  # TODO handle DOWN messages

  defp format({s, c, _}), do: format({s, c})
  defp format({s, c}), do: "#{s}.#{c}"
end
