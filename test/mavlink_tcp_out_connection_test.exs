defmodule XMAVLink.Test.TCPOutConnection do
  use ExUnit.Case

  alias XMAVLink.Frame
  alias XMAVLink.TCPOutConnection

  describe "forward/2" do
    test "sends MAVLink v1 frames over the TCP socket" do
      packet = <<0xFE, 0x00, 0x01, 0x01, 0x01, 0x00, 0x37, 0x92>>
      frame = %Frame{version: 1, mavlink_1_raw: packet}

      assert_forwarded_packet(frame, packet)
    end

    test "sends MAVLink v2 frames over the TCP socket" do
      packet = <<0xFD, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0xF8, 0x1B>>
      frame = %Frame{version: 2, mavlink_2_raw: packet}

      assert_forwarded_packet(frame, packet)
    end
  end

  defp assert_forwarded_packet(frame, expected_packet) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listen_socket)
    parent = self()

    acceptor =
      Task.async(fn ->
        case :gen_tcp.accept(listen_socket, 1_000) do
          {:ok, peer_socket} ->
            try do
              send(parent, :tcp_peer_accepted)
              :gen_tcp.recv(peer_socket, byte_size(expected_packet), 1_000)
            after
              :gen_tcp.close(peer_socket)
            end

          other ->
            other
        end
      end)

    try do
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

      try do
        assert_receive :tcp_peer_accepted, 1_000

        assert :ok =
                 TCPOutConnection.forward(%TCPOutConnection{socket: socket}, frame)

        assert {:ok, expected_packet} == Task.await(acceptor, 1_000)
      after
        :gen_tcp.close(socket)
      end
    after
      :gen_tcp.close(listen_socket)

      if Process.alive?(acceptor.pid) do
        Task.shutdown(acceptor, :brutal_kill)
      end
    end
  end
end
