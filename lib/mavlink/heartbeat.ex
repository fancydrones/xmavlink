defmodule XMAVLink.Heartbeat do
  @moduledoc """
  Emits MAVLink HEARTBEAT messages on a configurable interval.

  Most MAVLink nodes (cameras, GCSes, companion computers, autopilots)
  must emit a HEARTBEAT roughly once per second so peers know they're
  alive. Without it, dynamic / peer-learning routers like the
  reference `mavlink-router` don't forward traffic to them. xmavlink
  itself does not emit HEARTBEATs by default; consumers traditionally
  built and sent their own. This module standardises that pattern.

  ## Configuration

  Set `:heartbeat` in the application environment for `:xmavlink`. If
  the key is unset or `nil`, no HEARTBEATs are emitted (backwards
  compatible with versions ≤ 0.6.0).

  ### Static message

      config :xmavlink,
        heartbeat: [
          interval_ms: 1000,
          message: %Common.Message.Heartbeat{
            type: :mav_type_gcs,
            autopilot: :mav_autopilot_invalid,
            base_mode: MapSet.new(),
            custom_mode: 0,
            system_status: :mav_state_active,
            mavlink_version: 3
          }
        ]

  Suitable for nodes whose HEARTBEAT contents don't change at runtime
  (e.g. a stateless GCS).

  ### Dynamic builder

      config :xmavlink,
        heartbeat: [
          interval_ms: 1000,
          builder: {MyApp.Mavlink, :build_heartbeat, []}
        ]

  The `{module, function, args}` tuple is invoked on every tick to
  produce a fresh struct. Use this when `system_status`, `base_mode`,
  or `custom_mode` should reflect application state.

  Either `:message` or `:builder` is required (not both). `:interval_ms`
  is required.

  ## First heartbeat

  The first HEARTBEAT is dispatched immediately after init, so a
  peer-learning router admits the node within milliseconds rather than
  waiting up to a full interval.
  """

  use GenServer
  require Logger

  @doc false
  def start_link(spec) do
    GenServer.start_link(__MODULE__, spec, name: __MODULE__)
  end

  @impl true
  def init(spec) do
    interval_ms = Keyword.fetch!(spec, :interval_ms)
    builder = build_builder(spec)

    # First heartbeat ASAP so peer-learning routers admit us fast.
    send(self(), :tick)
    {:ok, %{interval_ms: interval_ms, builder: builder}}
  end

  @impl true
  def handle_info(:tick, state) do
    case safe_build(state.builder) do
      {:ok, msg} ->
        XMAVLink.Router.pack_and_send(msg)

      {:error, error} ->
        Logger.error("XMAVLink.Heartbeat builder failed: #{inspect(error)}")
    end

    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  defp build_builder(spec) do
    message = Keyword.get(spec, :message)
    builder_mfa = Keyword.get(spec, :builder)

    cond do
      message != nil and builder_mfa != nil ->
        raise ArgumentError,
              "XMAVLink heartbeat config: provide either :message or :builder, not both"

      message != nil ->
        fn -> message end

      builder_mfa != nil ->
        normalize_builder(builder_mfa)

      true ->
        raise ArgumentError,
              "XMAVLink heartbeat config must include either :message or :builder"
    end
  end

  defp normalize_builder({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a) do
    fn -> apply(m, f, a) end
  end

  defp normalize_builder(fun) when is_function(fun, 0), do: fun

  defp normalize_builder(other) do
    raise ArgumentError,
          "XMAVLink heartbeat :builder must be a {module, function, args} tuple " <>
            "or a 0-arity function, got: #{inspect(other)}"
  end

  defp safe_build(builder) do
    {:ok, builder.()}
  rescue
    error -> {:error, error}
  end
end
