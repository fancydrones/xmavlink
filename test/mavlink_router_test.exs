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

  describe "subscribe/1" do
    test "is synchronous - subscription is committed when call returns" do
      {:ok, pid} =
        Router.start_link(
          %{
            system: 1,
            component: 1,
            dialect: APM.Dialect,
            connection_strings: ["udpout:127.0.0.1:14555"]
          },
          []
        )

      # The SubscriptionCache is a named Agent that persists across Router
      # instances. Clear it on exit so a subscription from this test process
      # doesn't survive into the next test — otherwise the next Router init
      # restores the cached subscription, monitors a now-dead pid, and crashes
      # on the resulting :DOWN before its :local connection is registered.
      on_exit(fn ->
        if Process.whereis(XMAVLink.SubscriptionCache) do
          Agent.update(XMAVLink.SubscriptionCache, fn _ -> [] end)
        end
      end)

      assert :ok = Router.subscribe(source_system: 1)

      # The contract: by the time subscribe/1 returns, the subscription must
      # already be present in the Router's local connection state — callers
      # should not need a mailbox flush or sleep to observe it. We use
      # :sys.get_state here purely for test introspection of internal state;
      # production callers should never reach for it.
      state = :sys.get_state(XMAVLink.Router)
      subscriptions = state.connections[:local].subscriptions
      assert Enum.any?(subscriptions, fn {_query, subscriber} -> subscriber == self() end)

      Router.unsubscribe()
      GenServer.stop(pid)
    end
  end
end
