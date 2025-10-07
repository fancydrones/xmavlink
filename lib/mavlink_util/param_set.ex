defmodule XMAVLink.Util.ParamSet do
  @moduledoc false

  @params :params
  @param_retry_interval 3000

  require Logger
  alias XMAVLink.Router, as: MAV
  alias Common.Message.ParamValue
  alias Common.Message.ParamSet
  import XMAVLink.Util.FocusManager, only: [focus: 0]


  def param_set(param, new_value) do
    with {:ok, {system_id, component_id, mavlink_version}} <- focus() do
      param_set(system_id, component_id, mavlink_version, param, new_value)
    end
  end

  def param_set(system_id, component_id, mavlink_version, param, new_value) when is_atom(param)do
    param_set(system_id, component_id, mavlink_version,  param |> Atom.to_string() |> String.upcase(), new_value)
  end

  def param_set(system_id, component_id, mavlink_version, param, new_value) do
    with [{{^system_id, ^component_id, ^param}, {_time, %ParamValue{param_type: param_type}}}]
         <- :ets.lookup(@params, {system_id, component_id, param}) do
      MAV.subscribe message: ParamValue, source_system: system_id

      MAV.pack_and_send(%ParamSet{
        target_system: system_id,
        target_component: component_id,
        param_id: param,
        param_value: new_value,
        param_type: param_type,
      }, mavlink_version)

      receive do
        %ParamValue{param_id: ^param, param_value: ^new_value} ->
          MAV.unsubscribe()
          Logger.info("Set #{param |> String.downcase()} to #{inspect new_value} for vehicle #{system_id}.#{component_id}")
      after
          @param_retry_interval ->
            param_set(system_id, component_id, mavlink_version, param, new_value)
      end
    end
  end

end
