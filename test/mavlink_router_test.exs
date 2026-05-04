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

  describe "udpout reply handling" do
    # Regression for the NAT-mismatch echo loop: when a `udpout:` connection's
    # reply arrives from a source IP that differs from the configured target
    # (because NAT, masquerade, kube-proxy DNAT, or multipath routing
    # rewrote the reply's source), the router previously filed it as a
    # brand-new UDPInConnection at `{socket, reply_ip, reply_port}`. The
    # broadcast clause of `route/1` would then forward subsequent inbound
    # frames back out the original UDPOut — i.e. echo the host's traffic
    # back to itself, producing a sustained sub-millisecond loop with the
    # peer. Fixed by always attributing inbound on a UDPOut's socket to
    # that UDPOut, regardless of source IP.
    test "reply from a NAT'd source IP is attributed to the existing UDPOut, not filed as a phantom UDPInConnection" do
      {:ok, router_pid} =
        Router.start_link(
          %{
            system: 1,
            component: 1,
            dialect: Common,
            connection_strings: ["udpout:127.0.0.1:14556"]
          },
          []
        )

      on_exit(fn ->
        if Process.whereis(XMAVLink.SubscriptionCache) do
          Agent.update(XMAVLink.SubscriptionCache, fn _ -> [] end)
        end
      end)

      # The UDPOut is added asynchronously by the spawned connect/2 process,
      # so wait until it lands in `connections`.
      socket = wait_for_udpout_socket(router_pid)

      # Real HEARTBEAT bytes (msg_id 0) packed under Common: sysid=1,
      # compid=100, custom_mode=0, mav_type_quadrotor, autopilot=invalid,
      # mav_state_active. CRC validates under Common.
      raw_heartbeat =
        <<0xFD, 0x09, 0x00, 0x00, 0x0F, 0x01, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x1E, 0x00, 0x00, 0x03, 0x03, 0xC3, 0xBC>>

      # Reply arrives with a source IP different from the configured
      # target (127.0.0.1) — simulates NAT.
      fake_reply_ip = {10, 42, 0, 1}
      fake_reply_port = 14556

      send(router_pid, {:udp, socket, fake_reply_ip, fake_reply_port, raw_heartbeat})

      # `:sys.get_state/1` is synchronous — by the time it returns, the
      # `:udp` message has been processed.
      state = :sys.get_state(router_pid)

      refute Map.has_key?(state.connections, {socket, fake_reply_ip, fake_reply_port}),
             "router filed a phantom UDPInConnection for the NAT'd reply " <>
               "(would cause echo loop in production)"

      assert match?(%XMAVLink.UDPOutConnection{}, state.connections[socket]),
             "expected the UDPOut to remain registered under the bare socket key"

      GenServer.stop(router_pid)
    end

    # Regression for the secondary echo path: even after the broadcast-clause
    # fix above, a frame whose dialect classification is `:system_component`
    # (e.g. TIMESYNC, msg_id 111) goes through the *targeted* `route/1`
    # clause. That clause computes recipients via `matching_system_components`
    # which always includes `:local` and any connection in `routes` that
    # matches the target. With `target_system=0` (wildcard, as PX4's
    # TIMESYNC sends), every entry in `routes` matches — including the
    # UDPOut socket the frame just arrived on (because we just registered
    # `routes[{source_system, source_component}] = source_connection_key`).
    # Without source-exclusion, the targeted clause would forward the frame
    # back out the same UDPOut, producing the same echo as the broadcast
    # path did before 0.6.2.
    test "TIMESYNC reply is not echoed back via the udpout (regression: targeted route clause source-exclusion)" do
      # A real UDP listener stands in for the peer the udpout would forward
      # to. If the router echoes the frame, bytes arrive at this socket
      # and we'll detect it via `assert_receive`/`refute_receive`.
      {:ok, trap_socket} = :gen_udp.open(0, [:binary, active: true])
      {:ok, trap_port} = :inet.port(trap_socket)

      {:ok, router_pid} =
        Router.start_link(
          %{
            system: 1,
            component: 1,
            dialect: Common,
            connection_strings: ["udpout:127.0.0.1:#{trap_port}"]
          },
          []
        )

      on_exit(fn ->
        :gen_udp.close(trap_socket)

        if Process.whereis(XMAVLink.SubscriptionCache) do
          Agent.update(XMAVLink.SubscriptionCache, fn _ -> [] end)
        end
      end)

      udpout_socket = wait_for_udpout_socket(router_pid)

      # TIMESYNC v2 frame from sysid=1/compid=1 (PX4-style): msg_id 111,
      # target_system=0, target_component=0. CRC validates under Common.
      # Captured from a production xmavlink emitter.
      raw_timesync =
        <<0xFD, 0x0D, 0x00, 0x00, 0x37, 0x01, 0x01, 0x6F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00, 0xF8, 0x17, 0xE4, 0x36, 0x1B, 0x14, 0x31>>

      # Inject as if the reply arrived from a NAT'd source IP. The
      # specific IP doesn't matter for the targeted-clause echo bug —
      # what matters is that `routes[{1,1}]` ends up pointing at the
      # udpout_socket, which it does as soon as we attribute the frame
      # to the UDPOut.
      fake_reply_ip = {10, 42, 0, 1}
      send(router_pid, {:udp, udpout_socket, fake_reply_ip, trap_port, raw_timesync})

      # Sync with the router process.
      _state = :sys.get_state(router_pid)

      # If the router echoes, the trap socket's controlling process
      # (us) receives a `{:udp, _, _, _, _}` message. With the
      # source-exclusion fix in place, no echo should fire.
      refute_receive {:udp, ^trap_socket, _, _, _},
                     100,
                     "router echoed a :system_component-classified frame back via the udpout"

      GenServer.stop(router_pid)
    end

    defp wait_for_udpout_socket(router_pid, attempts \\ 50) do
      state = :sys.get_state(router_pid)

      udpout =
        Enum.find(state.connections, fn
          {key, %XMAVLink.UDPOutConnection{}} when is_port(key) -> true
          _ -> false
        end)

      cond do
        udpout != nil ->
          {socket, _} = udpout
          socket

        attempts > 0 ->
          Process.sleep(20)
          wait_for_udpout_socket(router_pid, attempts - 1)

        true ->
          flunk("UDPOut connection didn't materialize within timeout")
      end
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
