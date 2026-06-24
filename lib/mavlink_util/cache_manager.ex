defmodule XMAVLink.Util.CacheManager do
  @moduledoc """

  Populate and keep updated a set of protected ETS tables representing:

  - the visible MAV systems
  - the most recently received messages for each MAV and message type
  - the most recently received set of parameters for each MAV

  Using ETS tables allows clients to perform read only API operations directly
  on the tables, preventing this GenServer from becoming a bottleneck.

  Use `XMAVLink.Util.Context` when utility state should be scoped to a
  specific router, dialect, or ETS table namespace.
  """

  use GenServer
  require Logger
  alias XMAVLink.Util.{Context, Defaults, Tables}
  alias XMAVLink.Util.ParamRequest
  import XMAVLink.Util.FocusManager, only: [focus: 0, focus: 1]

  @one_second_loop :one_second_loop
  @five_second_loop :five_second_loop
  @ten_second_loop :ten_second_loop

  defstruct one_second_interval_ms: 1_000,
            five_second_interval_ms: 5_000,
            ten_second_interval_ms: 10_000,
            context: nil,
            router: nil,
            auto_param_request: true,
            dialect: Defaults.default_dialect(),
            table_prefix: nil,
            tables: Tables.names()

  # API

  def start_link(state, opts \\ []) do
    GenServer.start_link(__MODULE__, state, Keyword.put_new(opts, :name, __MODULE__))
  end

  def mavs(opts \\ []) do
    context = Context.new(opts)
    systems = context.tables.systems

    with :ok <- require_table(systems) do
      scids = :ets.foldl(fn {scid, _}, acc -> [scid | acc] end, [], systems)
      Logger.info("Listing #{length(scids)} visible vehicles")
      {:ok, scids}
    end
  end

  def router(opts \\ []) do
    cond do
      Keyword.has_key?(opts, :context) or Keyword.has_key?(opts, :router) ->
        Context.new(opts).router

      pid = GenServer.whereis(__MODULE__) ->
        GenServer.call(pid, :router)

      true ->
        Context.new().router
    end
  end

  def msg(), do: msg([])

  def msg(opts) when is_list(opts) do
    with {:ok, scid} <- focus(opts) do
      msg(scid, opts)
    end
  end

  def msg(scid = {_, _, _}), do: msg(scid, [])

  def msg(name) do
    with {:ok, scid} <- focus() do
      msg(scid, name)
    end
  end

  def msg(name, opts) when is_atom(name) and is_list(opts) do
    with {:ok, scid} <- focus(opts) do
      msg(scid, name, opts)
    end
  end

  def msg({system_id, component_id, _}, opts) when is_list(opts) do
    messages = Context.new(opts).tables.messages

    with :ok <- require_table(messages) do
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
          messages
        )
      }
    end
  end

  def msg(scid = {_, _, _}, msg_type) when is_atom(msg_type), do: msg(scid, msg_type, [])

  def msg({system_id, component_id, _}, msg_type, opts) when is_atom(msg_type) do
    messages = Context.new(opts).tables.messages

    with :ok <- require_table(messages),
         [{_key, {received, message}}] <-
           :ets.lookup(messages, {system_id, component_id, msg_type}) do
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

  def params(), do: params([])

  def params(opts) when is_list(opts) do
    with {:ok, scid} <- focus(opts) do
      params(scid, opts)
    end
  end

  def params(scid = {_, _, _}), do: params(scid, [])

  def params(match) when is_binary(match) do
    with {:ok, scid} <- focus() do
      params(scid, match)
    end
  end

  def params(match, opts) when is_binary(match) and is_list(opts) do
    with {:ok, scid} <- focus(opts) do
      params(scid, match, opts)
    end
  end

  def params(scid = {_, _, _}, opts) when is_list(opts) do
    params(scid, "", opts)
  end

  def params(scid = {_, _, _}, match) when is_binary(match), do: params(scid, match, [])

  def params({system_id, component_id, _mavlink_version}, match, opts) when is_binary(match) do
    context = Context.new(opts)
    params = context.tables.params
    param_value_module = message_module(context.dialect, :ParamValue)

    with :ok <- require_table(params),
         match_upcase <- String.upcase(match),
         param_map when is_map(param_map) <-
           :ets.foldl(
             fn
               {{^system_id, ^component_id, param_id},
                {_, %{__struct__: ^param_value_module, param_value: param_value}}},
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
             params
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
    opts = Map.new(opts)
    context = Context.new(opts)

    :ets.new(context.tables.messages, [:named_table, :protected, {:read_concurrency, true}, :set])

    :ets.new(context.tables.systems, [
      :named_table,
      :protected,
      {:read_concurrency, true},
      :ordered_set
    ])

    :ets.new(context.tables.params, [
      :named_table,
      :protected,
      {:read_concurrency, true},
      :ordered_set
    ])

    state =
      __MODULE__
      |> struct(
        opts
        |> Map.put(:context, context)
        |> Map.put(:router, context.router)
        |> Map.put(:dialect, context.dialect)
        |> Map.put(:table_prefix, context.table_prefix)
        |> Map.put(:tables, context.tables)
      )

    XMAVLink.Router.subscribe(state.context.router, as_frame: true)

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
      :ets.lookup(state.tables.messages, {source_system, source_component, message_type})

    # Replace with the new message
    :ets.insert(
      state.tables.messages,
      {{source_system, source_component, message_type}, {now(), message}}
    )

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
         %{type: type, mavlink_version: mavlink_minor_version} = message,
         mavlink_major_version,
         state
       ) do
    if match_message?(message, state.dialect, :Heartbeat) do
      # First time this MAV system seen, create a system record
      :ets.insert(
        state.tables.systems,
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
        "First sighting of vehicle #{source_system_id}.#{source_component_id}: #{describe(state.dialect, type)}"
      )

      if state.auto_param_request do
        spawn_link(ParamRequest, :param_request_list, [
          source_system_id,
          source_component_id,
          mavlink_major_version,
          [context: state.context]
        ])
      end
    end

    state
  end

  defp handle_mav_message(
         source_system_id,
         source_component_id,
         _,
         param_value_msg = %{param_id: param_id, param_count: param_count},
         _,
         state
       ) do
    if match_message?(param_value_msg, state.dialect, :ParamValue) do
      with [{_, system = %{param_count_loaded: param_count_loaded}}] <-
             :ets.lookup(state.tables.systems, {source_system_id, source_component_id}),
           is_new <-
             :ets.lookup(state.tables.params, {source_system_id, source_component_id, param_id})
             |> length
             |> Kernel.==(0),
           true <-
             :ets.insert(
               state.tables.params,
               {{source_system_id, source_component_id, param_id}, {now(), param_value_msg}}
             ) do
        # TODO Hidden parameters can become un-hidden, increasing param_count, in which case we need to spawn param_request_list again.
        :ets.insert(
          state.tables.systems,
          {
            {source_system_id, source_component_id},
            %{
              system
              | param_count: param_count,
                param_count_loaded:
                  if(is_new, do: param_count_loaded + 1, else: param_count_loaded)
            }
          }
        )
      end
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

  defp message_module(dialect, name), do: Module.concat([dialect, Message, name])

  defp match_message?(%{__struct__: module}, dialect, name),
    do: module == message_module(dialect, name)

  defp match_message?(_message, _dialect, _name), do: false

  defp describe(dialect, value) do
    if function_exported?(dialect, :describe, 1) do
      apply(dialect, :describe, [value])
    else
      inspect(value)
    end
  end
end
