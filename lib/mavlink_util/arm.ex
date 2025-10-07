defmodule XMAVLink.Util.Arm do
  @moduledoc false

  @arm_retry_interval 3000

  require Logger
  alias Common.Message.CommandLong
  alias Common.Message.Heartbeat
  alias XMAVLink.Router, as: MAV
  import XMAVLink.Util.CacheManager, only: [msg: 1]
  import XMAVLink.Util.FocusManager, only: [focus: 0]

  def arm() do
    with {:ok, {system_id, component_id, mavlink_version}} <- focus() do
      arm(system_id, component_id, mavlink_version)
    end
  end

  def arm(system_id, component_id, mavlink_version) do
    with {:ok, _, %Heartbeat{system_status: system_status}}
         when system_status in [
                :mav_state_standby,
                :mav_state_active,
                :mav_state_critical,
                :mav_state_emergency
              ] <-
           msg(Heartbeat) do
      MAV.subscribe(message: Heartbeat, source_system: system_id)

      MAV.pack_and_send(
        %CommandLong{
          command: :mav_cmd_component_arm_disarm,
          confirmation: 1,
          # Arm
          param1: 1.0,
          param2: 0.0,
          param3: 0.0,
          param4: 0.0,
          param5: 0.0,
          param6: 0.0,
          param7: 0.0,
          target_component: component_id,
          target_system: system_id
        },
        mavlink_version
      )

      receive do
        %Heartbeat{base_mode: base_mode} ->
          cond do
            :mav_mode_flag_safety_armed in base_mode ->
              MAV.unsubscribe()
              Logger.info("Armed vehicle #{system_id}.#{component_id}")
              :ok

            true ->
              arm(system_id, component_id, mavlink_version)
          end
      after
        @arm_retry_interval ->
          arm(system_id, component_id, mavlink_version)
      end
    else
      %Heartbeat{system_status: invalid_system_status} ->
        Logger.warning(
          "Cannot arm vehicle #{system_id}.#{component_id}: #{Common.describe(invalid_system_status)}"
        )

        {:error, :cannot_arm_invalid_vehicle_status}

      _ ->
        Logger.warning(
          "Could not determine current status of vehicle #{system_id}.#{component_id}"
        )

        {:error, :could_not_determine_vehicle_status}
    end
  end

  def disarm() do
    with {:ok, {system_id, component_id, mavlink_version}} <- focus() do
      disarm(system_id, component_id, mavlink_version)
    end
  end

  def disarm(system_id, component_id, mavlink_version) do
    MAV.subscribe(message: Heartbeat, source_system: system_id)

    MAV.pack_and_send(
      %CommandLong{
        command: :mav_cmd_component_arm_disarm,
        confirmation: 1,
        # Disarm
        param1: 0.0,
        param2: 0.0,
        param3: 0.0,
        param4: 0.0,
        param5: 0.0,
        param6: 0.0,
        param7: 0.0,
        target_component: component_id,
        target_system: system_id
      },
      mavlink_version
    )

    receive do
      %Heartbeat{base_mode: base_mode} ->
        cond do
          :mav_mode_flag_safety_armed not in base_mode ->
            MAV.unsubscribe()
            Logger.info("Disarmed vehicle #{system_id}.#{component_id}")
            :ok

          true ->
            disarm(system_id, component_id, mavlink_version)
        end
    after
      @arm_retry_interval ->
        disarm(system_id, component_id, mavlink_version)
    end
  end
end
