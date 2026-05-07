defmodule XMAVLink.Util.CacheManager do
  @moduledoc """

  Populate and keep updated a set of protected ETS tables representing:

  - the visible MAV systems
  - the most recently received messages for each MAV and message type
  - the most recently received set of parameters for each MAV

  Using ETS tables allows clients to perform read only API operations directly
  on the tables, preventing this GenServer from becoming a bottleneck.
  """

  use GenServer
  require Logger
  alias XMAVLink.Util.ParamRequest
  alias Common.Message.Heartbeat
  alias Common.Message.ParamValue
  import XMAVLink.Util.FocusManager, only: [focus: 0]

  @messages :messages
  @systems :systems
  @params :params
  @one_second_loop :one_second_loop
  @five_second_loop :five_second_loop
  @ten_second_loop :ten_second_loop

  defstruct one_second_interval_ms: 1_000,
            five_second_interval_ms: 5_000,
            ten_second_interval_ms: 10_000,
            router: nil

  # API

  def start_link(state, opts \\ []) do
    GenServer.start_link(__MODULE__, state, Keyword.put_new(opts, :name, __MODULE__))
  end

  def mavs() do
    with :ok <- require_table(@systems) do
      scids = :ets.foldl(fn {scid, _}, acc -> [scid | acc] end, [], @systems)
      Logger.info("Listing #{length(scids)} visible vehicles")
      {:ok, scids}
    end
  end

  def router() do
    case GenServer.whereis(__MODULE__) do
      nil ->
        Application.get_env(:xmavlink, :router_name, XMAVLink.Router) || XMAVLink.Router

      pid ->
        GenServer.call(pid, :router)
    end
  end

  def msg() do
    with {:ok, scid} <- focus() do
      msg(scid)
    end
  end

  def msg({system_id, component_id, _}) do
    with :ok <- require_table(@messages) do
      {
        :ok,
        :ets.foldl(
          fn
            {{^system_id, ^component_id, msg_type}, {received, msg}}, acc ->
              Enum.into([{msg_type, {now() - received, msg}}], acc)

            _, acc ->
              acc
          end,
          %{},
          @messages
        )
      }
    end
  end

  def msg(name) do
    with {:ok, scid} <- focus() do
      msg(scid, name)
    end
  end

  def msg({system_id, component_id, _}, msg_type) when is_atom(msg_type) do
    with :ok <- require_table(@messages),
         [{_key, {received, message}}] <-
           :ets.lookup(@messages, {system_id, component_id, msg_type}) do
      Logger.info("Most recent \"#{dequalify_msg_type(msg_type)}\" message")
      {:ok, now() - received, message}
    else
      {:error, :not_started} ->
        {:error, :not_started}

      _ ->
        Logger.warning(
          "Error attempting to retrieve message of type \"#{dequalify_msg_type(msg_type)}\""
        )

        {:error, :no_such_message}
    end
  end

  def params() do
    with {:ok, scid} <- focus() do
      params(scid)
    end
  end

  def params(scid = {_, _, _}) do
    params(scid, "")
  end

  def params(match) when is_binary(match) do
    with {:ok, scid} <- focus() do
      params(scid, match)
    end
  end

  def params({system_id, component_id, _mavlink_version}, match) when is_binary(match) do
    with :ok <- require_table(@params),
         match_upcase <- String.upcase(match),
         param_map when is_map(param_map) <-
           :ets.foldl(
             fn
               {{^system_id, ^component_id, param_id}, {_, %ParamValue{param_value: param_value}}},
               acc ->
                 if String.contains?(param_id, match_upcase) do
                   Enum.into([{param_id, param_value}], acc)
                 else
                   acc
                 end

               _, acc ->
                 acc
             end,
             %{},
             @params
           ) do
      Logger.info("Listing #{param_map |> Map.keys() |> length} parameters matching \"#{match}\"")
      {:ok, param_map}
    else
      {:error, :not_started} ->
        {:error, :not_started}

      _ ->
        Logger.warning("Error attempting to query params matching \"#{match}\"")
        {:error, :query_failed}
    end
  end

  @impl true
  def init(opts) do
    :ets.new(@messages, [:named_table, :protected, {:read_concurrency, true}, :set])
    :ets.new(@systems, [:named_table, :protected, {:read_concurrency, true}, :ordered_set])
    :ets.new(@params, [:named_table, :protected, {:read_concurrency, true}, :ordered_set])

    state = __MODULE__ |> struct(opts) |> normalize_router()
    XMAVLink.Router.subscribe(state.router, as_frame: true)

    {
      :ok,
      state
      |> schedule_one_second_loop()
      |> schedule_five_second_loop()
      |> schedule_ten_second_loop()
    }
  end

  @impl true
  def handle_call(:router, _caller, state) do
    {:reply, state.router, state}
  end

  def handle_call(_msg, _caller, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(
        %XMAVLink.Frame{
          message: message = %{__struct__: message_type},
          source_system: source_system,
          source_component: source_component,
          version: source_version
        },
        state
      ) do
    # Get the previously cached message of this type from the MAV, if any
    previous_message_list =
      :ets.lookup(@messages, {source_system, source_component, message_type})

    # Replace with the new message
    :ets.insert(@messages, {{source_system, source_component, message_type}, {now(), message}})

    # Delegate any message-specific behaviour to handle_mav_message()
    case previous_message_list do
      [] ->
        {:noreply,
         handle_mav_message(source_system, source_component, nil, message, source_version, state)}

      [previous_message] ->
        {:noreply,
         handle_mav_message(
           source_system,
           source_component,
           previous_message,
           message,
           source_version,
           state
         )}
    end
  end

  def handle_info(@one_second_loop, state) do
    schedule_one_second_loop(state)
    {:noreply, one_second_loop(state)}
  end

  def handle_info(@five_second_loop, state) do
    schedule_five_second_loop(state)
    {:noreply, five_second_loop(state)}
  end

  def handle_info(@ten_second_loop, state) do
    schedule_ten_second_loop(state)
    {:noreply, ten_second_loop(state)}
  end

  defp handle_mav_message(
         source_system_id,
         source_component_id,
         nil,
         %Heartbeat{type: type, mavlink_version: mavlink_minor_version},
         mavlink_major_version,
         state
       ) do
    # First time this MAV system seen, create a system record
    :ets.insert(
      @systems,
      {
        {source_system_id, source_component_id},
        # TODO System struct
        %{
          mavlink_major_version: mavlink_major_version,
          mavlink_minor_version: mavlink_minor_version,
          param_count: 0,
          param_count_loaded: 0
        }
      }
    )

    Logger.info(
      "First sighting of vehicle #{source_system_id}.#{source_component_id}: #{Common.describe(type)}"
    )

    spawn_link(ParamRequest, :param_request_list, [
      source_system_id,
      source_component_id,
      mavlink_major_version,
      [router: state.router]
    ])

    state
  end

  defp handle_mav_message(
         source_system_id,
         source_component_id,
         _,
         param_value_msg = %ParamValue{param_id: param_id, param_count: param_count},
         _,
         state
       ) do
    with [{_, system = %{param_count_loaded: param_count_loaded}}] <-
           :ets.lookup(@systems, {source_system_id, source_component_id}),
         is_new <-
           :ets.lookup(@params, {source_system_id, source_component_id, param_id})
           |> length
           |> Kernel.==(0),
         true <-
           :ets.insert(
             @params,
             {{source_system_id, source_component_id, param_id}, {now(), param_value_msg}}
           ) do
      # TODO Hidden parameters can become un-hidden, increasing param_count, in which case we need to spawn param_request_list again.
      :ets.insert(
        @systems,
        {
          {source_system_id, source_component_id},
          %{
            system
            | param_count: param_count,
              param_count_loaded: if(is_new, do: param_count_loaded + 1, else: param_count_loaded)
          }
        }
      )
    end

    state
  end

  defp handle_mav_message(_, _, _, _, _, state), do: state

  defp one_second_loop(state) do
    state
  end

  defp five_second_loop(state) do
    state
  end

  defp ten_second_loop(state) do
    state
  end

  defp schedule_one_second_loop(state) do
    :timer.send_after(state.one_second_interval_ms, @one_second_loop)
    state
  end

  defp schedule_five_second_loop(state) do
    :timer.send_after(state.five_second_interval_ms, @five_second_loop)
    state
  end

  defp schedule_ten_second_loop(state) do
    :timer.send_after(state.ten_second_interval_ms, @ten_second_loop)
    state
  end

  defp now(), do: :erlang.monotonic_time(:milli_seconds)

  defp dequalify_msg_type(msg_type) do
    to_string(msg_type)
    |> String.split(".")
    |> (fn parts -> parts |> Enum.reverse() |> List.first() end).()
  end

  defp require_table(table) do
    case :ets.info(table) do
      :undefined -> {:error, :not_started}
      _ -> :ok
    end
  end

  defp normalize_router(state = %{router: nil}) do
    %{
      state
      | router: Application.get_env(:xmavlink, :router_name, XMAVLink.Router) || XMAVLink.Router
    }
  end

  defp normalize_router(state), do: state
end
