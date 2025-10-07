defmodule XMAVLink.Util.ParamRequest do
  @moduledoc false

  @systems :systems
  @param_retry_interval 3000

  require Logger
  alias XMAVLink.Router, as: MAV
  import XMAVLink.Util.FocusManager, only: [focus: 0]


  def param_request_list() do
    with {:ok, {system_id, component_id, mavlink_version}} <- focus() do
      Logger.info("Waiting to receive first parameter from vehicle #{system_id}.#{component_id}")
      param_request_list(system_id, component_id, mavlink_version)
    end
  end

  def param_request_list(system_id, component_id, mavlink_version, last_param_count_loaded \\ 0) do
    with [{_, %{param_count: param_count, param_count_loaded: param_count_loaded}}] <- :ets.lookup(@systems, {system_id, component_id}),
         retry <- param_count_loaded == last_param_count_loaded,
         complete <- param_count_loaded == param_count and param_count > 0 do
      if complete do
        Logger.info("All #{param_count} parameters loaded for vehicle #{system_id}.#{component_id}")
      else
        if param_count > 0 do
          Logger.info("Loaded #{param_count_loaded}/#{param_count} parameters for vehicle #{system_id}.#{component_id}")
        end
        if retry do
          MAV.pack_and_send(%Common.Message.ParamRequestList{
            target_system: system_id, target_component: component_id}, mavlink_version)
        end
        Process.sleep(@param_retry_interval)
        param_request_list(system_id, component_id, mavlink_version, param_count_loaded)
      end
    end
  end

end
