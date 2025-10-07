defmodule XMAVLink.Util.SITL do
  @moduledoc """
  Provide SITL specific support e.g RC channel forwarding
  """

  require Logger
  alias XMAVLink.Router, as: MAV
  alias Common.Message.RcChannelsRaw
  alias Common.Message.RequestDataStream
  import XMAVLink.Util.FocusManager, only: [focus: 0]

  @resend_stream_interval 90

  def forward_rc(sitl_rc_in_port \\ 5501) do
    with {:ok, {system_id, component_id, mavlink_version}} <- focus() do
      forward_rc(system_id, component_id, mavlink_version, sitl_rc_in_port)
    end
  end

  def forward_rc(system_id, component_id, mavlink_version, sitl_rc_in_port) do
    Task.start_link(__MODULE__, :_connect, [
      system_id,
      component_id,
      mavlink_version,
      sitl_rc_in_port
    ])
  end

  def _connect(system_id, component_id, mavlink_version, sitl_rc_in_port) do
    with {:ok, socket} <- :gen_udp.open(0, [:binary, ip: {127, 0, 0, 1}]),
         :ok <-
           MAV.subscribe(
             message: RcChannelsRaw,
             source_system: system_id,
             source_component: component_id
           ) do
      Logger.info(
        "Start forwarding RC from vehicle #{system_id}.#{component_id} to SITL rc-in port #{sitl_rc_in_port}}"
      )

      _forward(system_id, component_id, mavlink_version, sitl_rc_in_port, socket, 0)
    else
      _ ->
        Logger.warning(
          "Could not subscribe or open port to forward RC from vehicle #{system_id}.#{component_id}"
        )
    end
  end

  def _forward(system_id, component_id, mavlink_version, sitl_rc_in_port, socket, 0) do
    MAV.pack_and_send(
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
      @resend_stream_interval
    )
  end

  def _forward(system_id, component_id, mavlink_version, sitl_rc_in_port, socket, count) do
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
          # TODO accept destination IP as parameter
          {127, 0, 0, 1},
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

        _forward(system_id, component_id, mavlink_version, sitl_rc_in_port, socket, count - 1)
    end
  end
end
