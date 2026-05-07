defmodule XMAVLink.Util.SITL do
  @moduledoc """
  Provides SITL-specific support such as RC channel forwarding.

  `forward_rc/2` starts a linked task that subscribes to `RC_CHANNELS_RAW`
  messages and forwards the eight primary channels as little-endian 16-bit
  values to a SITL RC input UDP endpoint. Pass `:router` to target a named
  router and `:destination_address` to forward somewhere other than
  `{127, 0, 0, 1}`.
  """

  require Logger
  import XMAVLink.Utils, only: [resolve_address: 1]

  alias XMAVLink.Util.CacheManager
  alias Common.Message.RcChannelsRaw
  alias Common.Message.RequestDataStream
  import XMAVLink.Util.FocusManager, only: [focus: 0]

  @resend_stream_interval 90

  def forward_rc(sitl_rc_in_port_or_opts \\ 5501, opts \\ [])

  def forward_rc(opts, []) when is_list(opts), do: forward_rc(5501, opts)

  def forward_rc(sitl_rc_in_port, opts) do
    with {:ok, {system_id, component_id, mavlink_version}} <- focus() do
      forward_rc(system_id, component_id, mavlink_version, sitl_rc_in_port, opts)
    end
  end

  def forward_rc(system_id, component_id, mavlink_version, sitl_rc_in_port, opts \\ []) do
    Task.start_link(__MODULE__, :_connect, [
      system_id,
      component_id,
      mavlink_version,
      sitl_rc_in_port,
      Keyword.get(opts, :router, CacheManager.router()),
      Keyword.get(opts, :destination_address, {127, 0, 0, 1})
    ])
  end

  def _connect(
        system_id,
        component_id,
        mavlink_version,
        sitl_rc_in_port,
        router,
        destination_address
      ) do
    with {:ok, destination_address} <- resolve_destination_address(destination_address),
         {:ok, socket} <- :gen_udp.open(0, [:binary, ip: {127, 0, 0, 1}]),
         :ok <-
           XMAVLink.Router.subscribe(
             router,
             message: RcChannelsRaw,
             source_system: system_id,
             source_component: component_id
           ) do
      Logger.info(
        "Start forwarding RC from vehicle #{system_id}.#{component_id} to SITL rc-in port #{sitl_rc_in_port}"
      )

      _forward(
        system_id,
        component_id,
        mavlink_version,
        sitl_rc_in_port,
        socket,
        0,
        router,
        destination_address
      )
    else
      {:error, reason} ->
        Logger.warning(
          "Could not subscribe or open port to forward RC from vehicle #{system_id}.#{component_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  def _forward(
        system_id,
        component_id,
        mavlink_version,
        sitl_rc_in_port,
        socket,
        0,
        router,
        destination_address
      ) do
    XMAVLink.Router.pack_and_send(
      router,
      %RequestDataStream{
        target_system: system_id,
        # APM Planner sends this, doesn't work with real component id
        target_component: 0,
        # TODO Not a bitmask, where is clue in MAVlink that this field is related?
        req_stream_id: Common.encode(:mav_data_stream_rc_channels, :mav_data_stream),
        req_message_rate: 18,
        start_stop: 1
      },
      mavlink_version
    )

    _forward(
      system_id,
      component_id,
      mavlink_version,
      sitl_rc_in_port,
      socket,
      @resend_stream_interval,
      router,
      destination_address
    )
  end

  def _forward(
        system_id,
        component_id,
        mavlink_version,
        sitl_rc_in_port,
        socket,
        count,
        router,
        destination_address
      ) do
    receive do
      %RcChannelsRaw{
        chan1_raw: c1,
        chan2_raw: c2,
        chan3_raw: c3,
        chan4_raw: c4,
        chan5_raw: c5,
        chan6_raw: c6,
        chan7_raw: c7,
        chan8_raw: c8
      } ->
        :gen_udp.send(
          socket,
          destination_address,
          sitl_rc_in_port,
          <<
            c1::little-unsigned-integer-size(16),
            c2::little-unsigned-integer-size(16),
            c3::little-unsigned-integer-size(16),
            c4::little-unsigned-integer-size(16),
            c5::little-unsigned-integer-size(16),
            c6::little-unsigned-integer-size(16),
            c7::little-unsigned-integer-size(16),
            c8::little-unsigned-integer-size(16)
          >>
        )

        _forward(
          system_id,
          component_id,
          mavlink_version,
          sitl_rc_in_port,
          socket,
          count - 1,
          router,
          destination_address
        )
    end
  end

  defp resolve_destination_address({a, b, c, d} = address)
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
       do: {:ok, address}

  defp resolve_destination_address(address) when is_tuple(address),
    do: {:error, :invalid_destination_address}

  defp resolve_destination_address(address) when is_binary(address), do: resolve_address(address)
  defp resolve_destination_address(_address), do: {:error, :invalid_destination_address}
end
