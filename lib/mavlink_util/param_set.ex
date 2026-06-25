defmodule XMAVLink.Util.ParamSet do
  @moduledoc """
  Convenience helper for setting cached MAVLink parameters.

  The helper uses the parameter type cached by `XMAVLink.Util.CacheManager`,
  sends `PARAM_SET`, and waits for a matching `PARAM_VALUE` confirmation.
  Retries are bounded by default; pass `:context`, `:retries`,
  `:retry_interval_ms`, or `:router` in the options to override the defaults.
  """

  @param_retry_interval 3000
  @param_retries 5

  require Logger
  alias XMAVLink.Util.Command
  import XMAVLink.Util.FocusManager, only: [focus: 1]

  def param_set(param, new_value, opts \\ []) when is_list(opts) do
    with {:ok, {system_id, component_id, mavlink_version}} <- focus(opts) do
      param_set(system_id, component_id, mavlink_version, param, new_value, opts)
    end
  end

  def param_set(system_id, component_id, mavlink_version, param, new_value, opts \\ []) do
    param = normalize_param_id(param)
    opts = Command.opts(opts, @param_retry_interval, @param_retries)
    params = opts.context.tables.params
    param_value_module = Command.message_module(opts.dialect, :ParamValue)

    with :ok <- Command.require_table(params),
         [
           {{^system_id, ^component_id, ^param},
            {_time, %{__struct__: ^param_value_module, param_type: param_type}}}
         ] <-
           :ets.lookup(params, {system_id, component_id, param}),
         :ok <-
           XMAVLink.Router.subscribe(opts.router,
             message: param_value_module,
             source_system: system_id
           ) do
      try do
        do_param_set(system_id, component_id, mavlink_version, param, new_value, param_type, opts)
      after
        XMAVLink.Router.unsubscribe(opts.router)
      end
    else
      [] -> {:error, :unknown_param}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_param_set(
         _system_id,
         _component_id,
         _mavlink_version,
         _param,
         _new_value,
         _param_type,
         _opts = %{attempts: 0}
       ),
       do: {:error, :timeout}

  defp do_param_set(system_id, component_id, mavlink_version, param, new_value, param_type, opts) do
    param_value_module = Command.message_module(opts.dialect, :ParamValue)

    with :ok <-
           XMAVLink.Router.pack_and_send(
             opts.router,
             struct(Command.message_module(opts.dialect, :ParamSet), %{
               target_system: system_id,
               target_component: component_id,
               param_id: param,
               param_value: new_value,
               param_type: param_type
             }),
             mavlink_version
           ) do
      receive do
        %{__struct__: ^param_value_module, param_id: ^param, param_value: ^new_value} ->
          Logger.info(
            "Set #{String.downcase(param)} to #{inspect(new_value)} for vehicle #{system_id}.#{component_id}"
          )

          :ok
      after
        opts.retry_interval_ms ->
          do_param_set(
            system_id,
            component_id,
            mavlink_version,
            param,
            new_value,
            param_type,
            %{opts | attempts: Command.next_attempts(opts.attempts)}
          )
      end
    end
  end

  defp normalize_param_id(param) when is_atom(param),
    do: param |> Atom.to_string() |> String.upcase()

  defp normalize_param_id(param) when is_binary(param), do: String.upcase(param)
end
