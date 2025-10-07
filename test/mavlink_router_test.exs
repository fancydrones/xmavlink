defmodule XMAVLink.Test.Router do
  use ExUnit.Case
  alias XMAVLink.Router

  describe "connection string parsing" do
    test "accepts IP address in udpout connection string" do
      # This should work as it did before
      assert {:ok, pid} =
               Router.start_link(
                 %{
                   system: 1,
                   component: 1,
                   dialect: APM.Dialect,
                   connection_strings: ["udpout:127.0.0.1:14550"]
                 },
                 []
               )

      GenServer.stop(pid)
    end

    test "accepts DNS hostname in udpout connection string" do
      # This should now work with DNS hostnames
      assert {:ok, pid} =
               Router.start_link(
                 %{
                   system: 1,
                   component: 1,
                   dialect: APM.Dialect,
                   connection_strings: ["udpout:localhost:14551"]
                 },
                 []
               )

      GenServer.stop(pid)
    end

    test "accepts IP address in tcpout connection string" do
      # TCP should also work with IP addresses
      assert {:ok, pid} =
               Router.start_link(
                 %{
                   system: 1,
                   component: 1,
                   dialect: APM.Dialect,
                   connection_strings: ["tcpout:127.0.0.1:14552"]
                 },
                 []
               )

      GenServer.stop(pid)
    end

    test "accepts DNS hostname in tcpout connection string" do
      # TCP should also work with DNS hostnames
      assert {:ok, pid} =
               Router.start_link(
                 %{
                   system: 1,
                   component: 1,
                   dialect: APM.Dialect,
                   connection_strings: ["tcpout:localhost:14553"]
                 },
                 []
               )

      GenServer.stop(pid)
    end

    test "rejects invalid hostname" do
      # Should fail gracefully with an invalid hostname
      # Trap exits so we can inspect the error
      Process.flag(:trap_exit, true)

      result =
        Router.start_link(
          %{
            system: 1,
            component: 1,
            dialect: APM.Dialect,
            connection_strings: [
              "udpout:this-hostname-definitely-does-not-exist-12345.invalid:14554"
            ]
          },
          []
        )

      # With trap_exit, start_link returns {:error, reason} instead of propagating the exit
      assert {:error, {%ArgumentError{message: message}, _stacktrace}} = result
      assert message =~ "invalid address"
      assert message =~ "this-hostname-definitely-does-not-exist-12345.invalid"
    end

    test "rejects invalid port" do
      # Should still reject invalid ports
      Process.flag(:trap_exit, true)

      result =
        Router.start_link(
          %{
            system: 1,
            component: 1,
            dialect: APM.Dialect,
            connection_strings: ["udpout:localhost:invalid"]
          },
          []
        )

      # With trap_exit, start_link returns {:error, reason}
      assert {:error, {%ArgumentError{message: message}, _stacktrace}} = result
      assert message =~ "invalid port"
    end

    test "rejects negative port" do
      # Should reject negative port numbers
      Process.flag(:trap_exit, true)

      result =
        Router.start_link(
          %{
            system: 1,
            component: 1,
            dialect: APM.Dialect,
            connection_strings: ["udpout:localhost:-1"]
          },
          []
        )

      # With trap_exit, start_link returns {:error, reason}
      assert {:error, {%ArgumentError{message: message}, _stacktrace}} = result
      assert message =~ "invalid port"
    end
  end
end
