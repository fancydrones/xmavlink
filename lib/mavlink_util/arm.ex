defmodule XMAVLink.Util.Arm do
  @moduledoc """
  Convenience helpers for arming and disarming a focused or explicit vehicle.

  The helpers are intended for the utility layer's selected router and return
  `:ok` or `{:error, reason}`. Retries are bounded by default; pass
  `:context`, `:retries`, `:retry_interval_ms`, or `:router` in the options to
  override the defaults.
  """

  @arm_retry_interval 3000
  @arm_retries 5

  require Logger
  alias XMAVLink.Util.CacheManager
  alias XMAVLink.Util.Context
  import XMAVLink.Util.FocusManager, only: [focus: 1]

  def arm(opts \\ []) when is_list(opts) do
    with {:ok, {system_id, component_id, mavlink_version}} <- focus(opts) do
      arm(system_id, component_id, mavlink_version, opts)
    end
  end

  def arm(system_id, component_id, mavlink_version, opts \\ []) do
    opts = command_opts(opts, @arm_retry_interval, @arm_retries)
    heartbeat_module = message_module(opts.dialect, :Heartbeat)

    with {:ok, _, %{__struct__: ^heartbeat_module, system_status: system_status}}
         when system_status in [
                :mav_state_standby,
                :mav_state_active,
                :mav_state_critical,
                :mav_state_emergency
              ] <-
           CacheManager.msg({system_id, component_id, mavlink_version}, heartbeat_module,
             context: opts.context
           ),
         :ok <-
           XMAVLink.Router.subscribe(opts.router,
             message: heartbeat_module,
             source_system: system_id
           ) do
      try do
        do_arm(system_id, component_id, mavlink_version, opts, opts.attempts)
      after
        XMAVLink.Router.unsubscribe(opts.router)
      end
    else
      {:ok, _, %{__struct__: ^heartbeat_module, system_status: invalid_system_status}} ->
        Logger.warning(
          "Cannot arm vehicle #{system_id}.#{component_id}: #{describe(opts.dialect, invalid_system_status)}"
        )

        {:error, :cannot_arm_invalid_vehicle_status}

      _ ->
        Logger.warning(
          "Could not determine current status of vehicle #{system_id}.#{component_id}"
        )

        {:error, :could_not_determine_vehicle_status}
    end
  end

  def disarm(opts \\ []) when is_list(opts) do
    with {:ok, {system_id, component_id, mavlink_version}} <- focus(opts) do
      disarm(system_id, component_id, mavlink_version, opts)
    end
  end

  def disarm(system_id, component_id, mavlink_version, opts \\ []) do
    opts = command_opts(opts, @arm_retry_interval, @arm_retries)
    heartbeat_module = message_module(opts.dialect, :Heartbeat)

    with :ok <-
           XMAVLink.Router.subscribe(opts.router,
             message: heartbeat_module,
             source_system: system_id
           ) do
      try do
        do_disarm(system_id, component_id, mavlink_version, opts, opts.attempts)
      after
        XMAVLink.Router.unsubscribe(opts.router)
      end
    end
  end

  defp do_arm(_system_id, _component_id, _mavlink_version, _opts, 0), do: {:error, :timeout}

  defp do_arm(system_id, component_id, mavlink_version, opts, attempts) do
    heartbeat_module = message_module(opts.dialect, :Heartbeat)

    with :ok <-
           XMAVLink.Router.pack_and_send(
             opts.router,
             arm_command(system_id, component_id, 1.0, opts.dialect),
             mavlink_version
           ) do
      receive do
        %{__struct__: ^heartbeat_module, base_mode: base_mode} ->
          if :mav_mode_flag_safety_armed in base_mode do
            Logger.info("Armed vehicle #{system_id}.#{component_id}")
            :ok
          else
            do_arm(system_id, component_id, mavlink_version, opts, next_attempts(attempts))
          end
      after
        opts.retry_interval_ms ->
          do_arm(system_id, component_id, mavlink_version, opts, next_attempts(attempts))
      end
    end
  end

  defp do_disarm(_system_id, _component_id, _mavlink_version, _opts, 0), do: {:error, :timeout}

  defp do_disarm(system_id, component_id, mavlink_version, opts, attempts) do
    heartbeat_module = message_module(opts.dialect, :Heartbeat)

    with :ok <-
           XMAVLink.Router.pack_and_send(
             opts.router,
             arm_command(system_id, component_id, 0.0, opts.dialect),
             mavlink_version
           ) do
      receive do
        %{__struct__: ^heartbeat_module, base_mode: base_mode} ->
          if :mav_mode_flag_safety_armed not in base_mode do
            Logger.info("Disarmed vehicle #{system_id}.#{component_id}")
            :ok
          else
            do_disarm(system_id, component_id, mavlink_version, opts, next_attempts(attempts))
          end
      after
        opts.retry_interval_ms ->
          do_disarm(system_id, component_id, mavlink_version, opts, next_attempts(attempts))
      end
    end
  end

  defp command_opts(opts, retry_interval_ms, retries) do
    context = opts |> Keyword.put(:router, CacheManager.router(opts)) |> Context.new()
    retries = Keyword.get(opts, :retries, retries)

    %{
      context: context,
      router: context.router,
      dialect: context.dialect,
      table_prefix: context.table_prefix,
      retry_interval_ms: Keyword.get(opts, :retry_interval_ms, retry_interval_ms),
      attempts: attempts(retries)
    }
  end

  defp attempts(:infinity), do: :infinity
  defp attempts(retries) when is_integer(retries) and retries >= 0, do: retries + 1

  defp next_attempts(:infinity), do: :infinity
  defp next_attempts(attempts), do: attempts - 1

  defp arm_command(system_id, component_id, arm, dialect) do
    struct(message_module(dialect, :CommandLong), %{
      command: :mav_cmd_component_arm_disarm,
      confirmation: 1,
      param1: arm,
      param2: 0.0,
      param3: 0.0,
      param4: 0.0,
      param5: 0.0,
      param6: 0.0,
      param7: 0.0,
      target_component: component_id,
      target_system: system_id
    })
  end

  defp message_module(dialect, name), do: Module.concat([dialect, Message, name])

  defp describe(dialect, value) do
    if function_exported?(dialect, :describe, 1) do
      apply(dialect, :describe, [value])
    else
      inspect(value)
    end
  end
end
