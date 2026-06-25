defmodule XMAVLink.Test.ConnectionInbound do
  use ExUnit.Case, async: true

  alias XMAVLink.Connection.Inbound
  alias XMAVLink.Frame
  alias XMAVLink.SerialConnection

  test "stream preserves oversized coalesced frame tails after a valid frame" do
    first_frame = unsigned_heartbeat_frame(1)
    second_frame = unsigned_heartbeat_frame(2)
    tail = :binary.copy(second_frame.mavlink_2_raw, 300)
    raw = first_frame.mavlink_2_raw <> tail
    connection = %SerialConnection{port: "ttyS0", buffer: <<>>}

    assert {:ok, "ttyS0", updated_connection, %Frame{message: %Common.Message.Heartbeat{}}} =
             Inbound.stream(raw, connection, <<>>, "ttyS0", Common, "test")

    assert updated_connection.buffer == tail
    assert_receive {:circuits_uart, "ttyS0", <<>>}, 20

    assert {:ok, "ttyS0", next_connection, %Frame{sequence_number: 2}} =
             Inbound.stream(
               <<>>,
               updated_connection,
               updated_connection.buffer,
               "ttyS0",
               Common,
               "test"
             )

    assert byte_size(next_connection.buffer) ==
             byte_size(tail) - byte_size(second_frame.mavlink_2_raw)
  end

  defp unsigned_heartbeat_frame(sequence_number) do
    {:ok, message_id, {:ok, crc_extra, _expected_length, _target}, payload} =
      XMAVLink.Message.pack(sample_heartbeat(), 2)

    Frame.pack_frame(%Frame{
      version: 2,
      sequence_number: sequence_number,
      source_system: 1,
      source_component: 1,
      message_id: message_id,
      payload: payload,
      crc_extra: crc_extra
    })
  end

  defp sample_heartbeat do
    %Common.Message.Heartbeat{
      type: :mav_type_gcs,
      autopilot: :mav_autopilot_invalid,
      base_mode: MapSet.new(),
      custom_mode: 0,
      system_status: :mav_state_active,
      mavlink_version: 3
    }
  end
end
