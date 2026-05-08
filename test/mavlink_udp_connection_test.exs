defmodule XMAVLink.Test.UDPConnection do
  use ExUnit.Case, async: true

  alias XMAVLink.UDPInConnection
  alias XMAVLink.UDPOutConnection

  @incompatible_mavlink_2_frame <<0xFD, 0, 1, 0, 0, 1, 1, 0::little-unsigned-integer-size(24),
                                  0::little-unsigned-integer-size(16)>>
  @incomplete_mavlink_1_frame <<0xFE, 1, 0, 1>>
  @incomplete_mavlink_2_frame <<0xFD, 0, 1, 0, 0, 1, 1>>

  describe "handle_info/3" do
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
    end
  end
end
