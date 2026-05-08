defmodule XMAVLink.Test.UDPConnection do
  use ExUnit.Case, async: true

  alias XMAVLink.Frame
  alias XMAVLink.Signing
  alias XMAVLink.UDPInConnection
  alias XMAVLink.UDPOutConnection

  @secret_key :binary.copy(<<42>>, 32)
  @link_id 9
  @local_timestamp 10_000_000
  @valid_timestamp 10_000_001

  @signed_mavlink_2_frame <<0xFD, 0, 1, 0, 0, 1, 1, 0::little-unsigned-integer-size(24),
                            0::little-unsigned-integer-size(16), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
                            11, 12, 13>>
  @incompatible_mavlink_2_frame <<0xFD, 0, 2, 0, 0, 1, 1, 0::little-unsigned-integer-size(24),
                                  0::little-unsigned-integer-size(16)>>
  @incomplete_mavlink_1_frame <<0xFE, 1, 0, 1>>
  @incomplete_mavlink_2_frame <<0xFD, 0, 1, 0, 0, 1, 1>>
  @incomplete_signed_mavlink_2_frame <<0xFD, 0, 1, 0, 0, 1, 1,
                                       0::little-unsigned-integer-size(24),
                                       0::little-unsigned-integer-size(16)>>

  describe "handle_info/3" do
    test "UDPIn rejects MAVLink 2 signed frames when signing is disabled" do
      socket = :socket
      address = {127, 0, 0, 1}
      port = 14_550

      connection = %UDPInConnection{socket: socket, address: address, port: port}

      assert {:error, :signed_frame_unsupported, {^socket, ^address, ^port}, ^connection} =
               UDPInConnection.handle_info(
                 {:udp, socket, address, port, @signed_mavlink_2_frame},
                 connection,
                 Common
               )
    end

    test "UDPIn accepts valid signed MAVLink 2 frames when signing is configured" do
      socket = :socket
      address = {127, 0, 0, 1}
      port = 14_550

      connection = %UDPInConnection{
        socket: socket,
        address: address,
        port: port,
        signing: signing()
      }

      raw = signed_heartbeat_frame().mavlink_2_raw

      assert {:ok, {^socket, ^address, ^port}, updated_connection,
              %Frame{
                source_system: 1,
                source_component: 1,
                signature: %{link_id: @link_id, timestamp: @valid_timestamp},
                message: %Common.Message.Heartbeat{}
              }} =
               UDPInConnection.handle_info({:udp, socket, address, port, raw}, connection, Common)

      assert updated_connection.signing.stream_timestamps[{1, 1, @link_id}] ==
               @valid_timestamp
    end

    test "UDPIn drops MAVLink 2 frames with incompatible flags" do
      socket = :socket
      address = {127, 0, 0, 1}
      port = 14_550

      connection = %UDPInConnection{socket: socket, address: address, port: port}

      assert {:error, :incompatible_flags, {^socket, ^address, ^port}, ^connection} =
               UDPInConnection.handle_info(
                 {:udp, socket, address, port, @incompatible_mavlink_2_frame},
                 connection,
                 Common
               )
    end

    test "UDPIn reports incomplete MAVLink frames separately" do
      socket = :socket
      address = {127, 0, 0, 1}
      port = 14_550

      connection = %UDPInConnection{socket: socket, address: address, port: port}

      assert {:error, :incomplete_frame, {^socket, ^address, ^port}, ^connection} =
               UDPInConnection.handle_info(
                 {:udp, socket, address, port, @incomplete_mavlink_1_frame},
                 connection,
                 Common
               )

      assert {:error, :incomplete_frame, {^socket, ^address, ^port}, ^connection} =
               UDPInConnection.handle_info(
                 {:udp, socket, address, port, @incomplete_mavlink_2_frame},
                 connection,
                 Common
               )

      assert {:error, :incomplete_frame, {^socket, ^address, ^port}, ^connection} =
               UDPInConnection.handle_info(
                 {:udp, socket, address, port, @incomplete_signed_mavlink_2_frame},
                 connection,
                 Common
               )
    end

    test "UDPOut rejects MAVLink 2 signed frames when signing is disabled" do
      socket = :socket
      address = {127, 0, 0, 1}
      port = 14_550

      connection = %UDPOutConnection{socket: socket, address: address, port: port}

      assert {:error, :signed_frame_unsupported, ^socket, ^connection} =
               UDPOutConnection.handle_info(
                 {:udp, socket, address, port, @signed_mavlink_2_frame},
                 connection,
                 Common
               )
    end

    test "UDPOut rejects unsigned MAVLink 2 frames when signing requires signed input" do
      socket = :socket
      address = {127, 0, 0, 1}
      port = 14_550

      connection = %UDPOutConnection{
        socket: socket,
        address: address,
        port: port,
        signing: signing()
      }

      assert {:error, :unsigned_frame_rejected, ^socket, ^connection} =
               UDPOutConnection.handle_info(
                 {:udp, socket, address, port, unsigned_heartbeat_frame().mavlink_2_raw},
                 connection,
                 Common
               )
    end

    test "UDPOut drops MAVLink 2 frames with incompatible flags" do
      socket = :socket
      address = {127, 0, 0, 1}
      port = 14_550

      connection = %UDPOutConnection{socket: socket, address: address, port: port}

      assert {:error, :incompatible_flags, ^socket, ^connection} =
               UDPOutConnection.handle_info(
                 {:udp, socket, address, port, @incompatible_mavlink_2_frame},
                 connection,
                 Common
               )
    end

    test "UDPOut reports incomplete MAVLink frames separately" do
      socket = :socket
      address = {127, 0, 0, 1}
      port = 14_550

      connection = %UDPOutConnection{socket: socket, address: address, port: port}

      assert {:error, :incomplete_frame, ^socket, ^connection} =
               UDPOutConnection.handle_info(
                 {:udp, socket, address, port, @incomplete_mavlink_1_frame},
                 connection,
                 Common
               )

      assert {:error, :incomplete_frame, ^socket, ^connection} =
               UDPOutConnection.handle_info(
                 {:udp, socket, address, port, @incomplete_mavlink_2_frame},
                 connection,
                 Common
               )

      assert {:error, :incomplete_frame, ^socket, ^connection} =
               UDPOutConnection.handle_info(
                 {:udp, socket, address, port, @incomplete_signed_mavlink_2_frame},
                 connection,
                 Common
               )
    end
  end

  defp signing do
    {:ok, signing} =
      Signing.new(
        secret_key: @secret_key,
        link_id: @link_id,
        timestamp: @local_timestamp
      )

    signing
  end

  defp signed_heartbeat_frame(timestamp \\ @valid_timestamp) do
    {:ok, frame} = Frame.sign_frame(unsigned_heartbeat_frame(), @secret_key, @link_id, timestamp)
    frame
  end

  defp unsigned_heartbeat_frame do
    {:ok, message_id, {:ok, crc_extra, _expected_length, _target}, payload} =
      XMAVLink.Message.pack(sample_heartbeat(), 2)

    Frame.pack_frame(%Frame{
      version: 2,
      sequence_number: 7,
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
