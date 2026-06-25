defmodule XMAVLink.Util.ParamRequest do
  @moduledoc """
  Convenience helper for requesting a vehicle's full parameter list.

  The helper watches `XMAVLink.Util.CacheManager` state and resends
  `PARAM_REQUEST_LIST` while the cached parameter count is not progressing.
  Retries are bounded by default; pass `:context`, `:retries`,
  `:retry_interval_ms`, or `:router` in the options to override the defaults.
  """

  @param_retry_interval 3000
  @param_retries 10

  require Logger
  alias XMAVLink.Util.Command
  import XMAVLink.Util.FocusManager, only: [focus: 1]

  def param_request_list(opts \\ []) when is_list(opts) do
    with {:ok, {system_id, component_id, mavlink_version}} <- focus(opts) do
      Logger.info("Waiting to receive first parameter from vehicle #{system_id}.#{component_id}")
      param_request_list(system_id, component_id, mavlink_version, opts)
    end
  end

  def param_request_list(system_id, component_id, mavlink_version, _opts_or_last \\ [])

  def param_request_list(system_id, component_id, mavlink_version, opts) when is_list(opts) do
    opts = Command.opts(opts, @param_retry_interval, @param_retries)
    do_param_request_list(system_id, component_id, mavlink_version, 0, opts)
  end

  def param_request_list(system_id, component_id, mavlink_version, last_param_count_loaded)
      when is_integer(last_param_count_loaded) do
    opts = Command.opts([], @param_retry_interval, @param_retries)
    do_param_request_list(system_id, component_id, mavlink_version, last_param_count_loaded, opts)
  end

  defp do_param_request_list(
         system_id,
         component_id,
         mavlink_version,
         last_param_count_loaded,
         opts
       ) do
    systems = opts.context.tables.systems

    with :ok <- Command.require_table(systems),
         [{_, %{param_count: param_count, param_count_loaded: param_count_loaded}}] <-
           :ets.lookup(systems, {system_id, component_id}),
         retry <- param_count_loaded == last_param_count_loaded,
         complete <- param_count_loaded == param_count and param_count > 0 do
      cond do
        complete ->
          Logger.info(
            "All #{param_count} parameters loaded for vehicle #{system_id}.#{component_id}"
          )

        retry and opts.attempts == 0 ->
          {:error, :timeout}

        true ->
          if param_count > 0 do
            Logger.info(
              "Loaded #{param_count_loaded}/#{param_count} parameters for vehicle #{system_id}.#{component_id}"
            )
          end

          with :ok <-
                 maybe_send_param_request(retry, system_id, component_id, mavlink_version, opts) do
            opts =
              if retry do
                %{opts | attempts: Command.next_attempts(opts.attempts)}
              else
                %{
                  opts
                  | attempts:
                      Command.attempts(Keyword.get(opts.source_opts, :retries, @param_retries))
                }
              end

            Process.sleep(opts.retry_interval_ms)

            do_param_request_list(
              system_id,
              component_id,
              mavlink_version,
              param_count_loaded,
              opts
            )
          end
      end
    else
      [] -> {:error, :no_such_mav}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_send_param_request(false, _system_id, _component_id, _mavlink_version, _opts),
    do: :ok

  defp maybe_send_param_request(true, system_id, component_id, mavlink_version, opts) do
    XMAVLink.Router.pack_and_send(
      opts.router,
      struct(Command.message_module(opts.dialect, :ParamRequestList), %{
        target_system: system_id,
        target_component: component_id
      }),
      mavlink_version
    )
  end
end
