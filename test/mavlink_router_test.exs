defmodule XMAVLink.Test.Router do
  use ExUnit.Case
  alias XMAVLink.Router

  describe "connection string parsing" do
    test "accepts IP address in udpout connection string" do
      {udp_socket, udp_port} = open_udp_socket()
      on_exit(fn -> :gen_udp.close(udp_socket) end)

      assert {:ok, pid} =
               Router.start_link(
                 %{
                   system: 1,
                   component: 1,
                   dialect: APM.Dialect,
                   connection_strings: ["udpout:127.0.0.1:#{udp_port}"]
                 },
                 []
               )

      GenServer.stop(pid)
    end

    test "accepts DNS hostname in udpout connection string" do
      {udp_socket, udp_port} = open_udp_socket()
      on_exit(fn -> :gen_udp.close(udp_socket) end)

      assert {:ok, pid} =
               Router.start_link(
                 %{
                   system: 1,
                   component: 1,
                   dialect: APM.Dialect,
                   connection_strings: ["udpout:localhost:#{udp_port}"]
                 },
                 []
               )

      GenServer.stop(pid)
    end

    test "accepts IP address in tcpout connection string" do
      {listen_socket, acceptor, port} = open_tcp_listener()
      on_exit(fn -> close_tcp_listener(listen_socket, acceptor) end)

      assert {:ok, pid} =
               Router.start_link(
                 %{
                   system: 1,
                   component: 1,
                   dialect: APM.Dialect,
                   connection_strings: ["tcpout:127.0.0.1:#{port}"]
                 },
                 []
               )

      assert_receive :tcp_peer_accepted, 1_000

      GenServer.stop(pid)
    end

    test "accepts DNS hostname in tcpout connection string" do
      {listen_socket, acceptor, port} = open_tcp_listener()
      on_exit(fn -> close_tcp_listener(listen_socket, acceptor) end)

      assert {:ok, pid} =
               Router.start_link(
                 %{
                   system: 1,
                   component: 1,
                   dialect: APM.Dialect,
                   connection_strings: ["tcpout:localhost:#{port}"]
                 },
                 []
               )

      assert_receive :tcp_peer_accepted, 1_000

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

    test "rejects invalid connection retry delays" do
      assert_raise ArgumentError, ~r/connection_retry_ms/, fn ->
        Router.start_link(
          %{
            system: 1,
            component: 1,
            dialect: APM.Dialect,
            connection_strings: [],
            connection_retry_ms: -1
          },
          []
        )
      end
    end
  end

  describe "connection lifecycle" do
    test "starts configured connections as supervised workers" do
      {udp_socket, udp_port} = open_udp_socket()
      on_exit(fn -> :gen_udp.close(udp_socket) end)

      assert {:ok, router_pid} =
               Router.start_link(
                 %{
                   system: 1,
                   component: 1,
                   dialect: APM.Dialect,
                   connection_strings: ["udpout:127.0.0.1:#{udp_port}"],
                   connection_retry_ms: 10
                 },
                 []
               )

      socket = wait_for_udpout_socket(router_pid)
      state = :sys.get_state(router_pid)

      assert Process.alive?(state.connection_supervisor)
      assert worker = state.connection_workers[socket]
      assert Process.alive?(worker)

      assert Enum.any?(DynamicSupervisor.which_children(state.connection_supervisor), fn
               {_id, ^worker, :worker, [XMAVLink.ConnectionWorker]} -> true
               _ -> false
             end)

      GenServer.stop(router_pid)
    end

    test "tcpout workers reconnect after the peer closes" do
      {listen_socket, acceptor, port} = open_tcp_reconnect_listener(2)
      on_exit(fn -> close_tcp_reconnect_listener(listen_socket, acceptor) end)

      assert {:ok, router_pid} =
               Router.start_link(
                 %{
                   system: 1,
                   component: 1,
                   dialect: APM.Dialect,
                   connection_strings: ["tcpout:127.0.0.1:#{port}"],
                   connection_retry_ms: 10
                 },
                 []
               )

      assert_receive {:tcp_peer_accepted, 1}, 1_000
      assert_receive {:tcp_peer_accepted, 2}, 1_000

      GenServer.stop(router_pid)
    end
  end

  describe "router instances" do
    test "child specs use the configured router name as the child id" do
      router_name = XMAVLink.Test.Router.ChildSpecRouter

      assert %{
               id: ^router_name,
               start:
                 {Router, :start_link,
                  [
                    %{
                      name: ^router_name,
                      system: 1,
                      component: 1,
                      dialect: Common,
                      connections: [],
                      connection_strings: []
                    }
                  ]}
             } =
               Router.child_spec(%{
                 name: router_name,
                 system: 1,
                 component: 1,
                 dialect: Common,
                 connections: []
               })
    end

    test "child specs require an explicit id for unnamed routers" do
      assert_raise ArgumentError, ~r/requires :id when :name is nil/, fn ->
        Router.child_spec(%{
          name: nil,
          system: 1,
          component: 1,
          dialect: Common,
          connections: []
        })
      end

      assert %{
               id: :unnamed_router,
               start: {Router, :start_link, [%{name: nil}]}
             } =
               Router.child_spec(%{
                 id: :unnamed_router,
                 name: nil,
                 system: 1,
                 component: 1,
                 dialect: Common,
                 connections: []
               })
    end

    test "targets subscriptions and outbound sends to a named router" do
      router_name = XMAVLink.Test.Router.NamedRouter

      {:ok, router_pid} =
        Router.start_link(%{
          name: router_name,
          system: 42,
          component: 100,
          dialect: Common,
          connection_strings: []
        })

      on_exit(fn ->
        stop_router(router_pid)
        stop_subscription_cache(router_name)
      end)

      assert :ok =
               Router.subscribe(router_name, message: Common.Message.Heartbeat, as_frame: true)

      msg = sample_heartbeat()
      assert :ok = Router.pack_and_send(router_name, msg)

      assert_receive %XMAVLink.Frame{
                       message: ^msg,
                       source_system: 42,
                       source_component: 100
                     },
                     200

      state = :sys.get_state(router_name)
      assert state.name == router_name
      assert state.subscription_cache == subscription_cache_name(router_name)

      Router.unsubscribe(router_name)
    end

    test "keeps subscriptions isolated between named routers" do
      router_a = XMAVLink.Test.Router.NamedRouterA
      router_b = XMAVLink.Test.Router.NamedRouterB

      {:ok, pid_a} =
        Router.start_link(%{
          name: router_a,
          system: 1,
          component: 100,
          dialect: Common,
          connection_strings: []
        })

      {:ok, pid_b} =
        Router.start_link(%{
          name: router_b,
          system: 2,
          component: 100,
          dialect: Common,
          connection_strings: []
        })

      on_exit(fn ->
        stop_router(pid_a)
        stop_router(pid_b)
        stop_subscription_cache(router_a)
        stop_subscription_cache(router_b)
      end)

      assert :ok = Router.subscribe(router_a, message: Common.Message.Heartbeat, as_frame: true)

      msg = sample_heartbeat()
      assert :ok = Router.pack_and_send(router_b, msg)

      refute_receive %XMAVLink.Frame{source_system: 2}, 50

      assert :ok = Router.pack_and_send(router_a, msg)

      assert_receive %XMAVLink.Frame{
                       message: ^msg,
                       source_system: 1,
                       source_component: 100
                     },
                     200

      Router.unsubscribe(router_a)
    end

    test "targets an unregistered router by pid" do
      {:ok, router_pid} =
        Router.start_link(%{
          name: nil,
          system: 3,
          component: 100,
          dialect: Common,
          connection_strings: []
        })

      on_exit(fn -> stop_router(router_pid) end)

      assert :ok =
               Router.subscribe(router_pid, message: Common.Message.Heartbeat, as_frame: true)

      msg = sample_heartbeat()
      assert :ok = Router.pack_and_send(router_pid, msg)

      assert_receive %XMAVLink.Frame{
                       message: ^msg,
                       source_system: 3,
                       source_component: 100
                     },
                     200

      state = :sys.get_state(router_pid)
      assert state.name == nil
      assert state.subscription_cache == nil

      Router.unsubscribe(router_pid)
    end

    test "normalizes :unknown subscriptions to the downstream unknown-message sentinel" do
      router_name = XMAVLink.Test.Router.UnknownMessageRouter

      {:ok, router_pid} =
        Router.start_link(%{
          name: router_name,
          system: 4,
          component: 100,
          dialect: Common,
          connection_strings: []
        })

      on_exit(fn ->
        stop_router(router_pid)
        stop_subscription_cache(router_name)
      end)

      assert :ok = Router.subscribe(router_name, message: :unknown, as_frame: true)

      subscriber = self()
      state = :sys.get_state(router_name)
      [{query, ^subscriber}] = state.connections.local.subscriptions
      assert query.message == XMAVLink.UnknownMessage

      XMAVLink.LocalConnection.forward(state.connections.local, %XMAVLink.Frame{
        source_system: 1,
        source_component: 1,
        target_system: 0,
        target_component: 0,
        target: :broadcast,
        message: nil
      })

      assert_receive %XMAVLink.Frame{message: %{__struct__: XMAVLink.UnknownMessage}}, 200

      Router.unsubscribe(router_name)
    end

    test "rejects invalid router target shapes" do
      assert_raise ArgumentError, ~r/invalid router target nil/, fn ->
        Router.subscribe(nil, [])
      end

      assert_raise ArgumentError, ~r/invalid router target {:bad}/, fn ->
        Router.pack_and_send({:bad}, sample_heartbeat())
      end
    end

    test "raises when a named router target is not running" do
      assert_raise ArgumentError,
                   ~r/router target {:global, :missing_router} is not running/,
                   fn ->
                     Router.pack_and_send({:global, :missing_router}, sample_heartbeat())
                   end
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
      {udp_socket, udp_port} = open_udp_socket()

      {:ok, router_pid} =
        Router.start_link(
          %{
            system: 1,
            component: 1,
            dialect: Common,
            connection_strings: ["udpout:127.0.0.1:#{udp_port}"]
          },
          []
        )

      on_exit(fn ->
        :gen_udp.close(udp_socket)

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
      fake_reply_port = udp_port

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
                     50,
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
      {udp_socket, udp_port} = open_udp_socket()

      {:ok, pid} =
        Router.start_link(
          %{
            system: 1,
            component: 1,
            dialect: APM.Dialect,
            connection_strings: ["udpout:127.0.0.1:#{udp_port}"]
          },
          []
        )

      # The SubscriptionCache is a named Agent that persists across Router
      # instances. Clear it on exit so a subscription from this test process
      # doesn't survive into the next test — otherwise the next Router init
      # restores the cached subscription, monitors a now-dead pid, and crashes
      # on the resulting :DOWN before its :local connection is registered.
      on_exit(fn ->
        :gen_udp.close(udp_socket)

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

  describe "pack_and_send/3" do
    test "can override the local source identity for one message" do
      {:ok, pid} =
        Router.start_link(
          %{
            system: 1,
            component: 100,
            dialect: Common,
            connection_strings: []
          },
          []
        )

      on_exit(fn ->
        if Process.whereis(XMAVLink.SubscriptionCache) do
          Agent.update(XMAVLink.SubscriptionCache, fn _ -> [] end)
        end
      end)

      assert :ok = Router.subscribe(message: Common.Message.Heartbeat, as_frame: true)

      msg = %Common.Message.Heartbeat{
        type: :mav_type_gcs,
        autopilot: :mav_autopilot_invalid,
        base_mode: MapSet.new(),
        custom_mode: 0,
        system_status: :mav_state_active,
        mavlink_version: 3
      }

      assert :ok = Router.pack_and_send(msg, 2, source_system: 245, source_component: 191)

      assert_receive %XMAVLink.Frame{
                       message: ^msg,
                       source_system: 245,
                       source_component: 191
                     },
                     200

      Router.unsubscribe()
      GenServer.stop(pid)
    end

    test "keeps independent sequence numbers per local source identity" do
      {:ok, pid} =
        Router.start_link(
          %{
            system: 1,
            component: 100,
            dialect: Common,
            connection_strings: []
          },
          []
        )

      on_exit(fn ->
        if Process.whereis(XMAVLink.SubscriptionCache) do
          Agent.update(XMAVLink.SubscriptionCache, fn _ -> [] end)
        end
      end)

      assert :ok = Router.subscribe(message: Common.Message.Heartbeat, as_frame: true)

      msg = sample_heartbeat()

      assert :ok = Router.pack_and_send(msg)

      assert_receive %XMAVLink.Frame{
                       source_system: 1,
                       source_component: 100,
                       sequence_number: 0
                     },
                     200

      assert :ok = Router.pack_and_send(msg, 2, source_system: 245, source_component: 191)

      assert_receive %XMAVLink.Frame{
                       source_system: 245,
                       source_component: 191,
                       sequence_number: 0
                     },
                     200

      assert :ok = Router.pack_and_send(msg)

      assert_receive %XMAVLink.Frame{
                       source_system: 1,
                       source_component: 100,
                       sequence_number: 1
                     },
                     200

      assert :ok = Router.pack_and_send(msg, 2, source_system: 245, source_component: 191)

      assert_receive %XMAVLink.Frame{
                       source_system: 245,
                       source_component: 191,
                       sequence_number: 1
                     },
                     200

      Router.unsubscribe()
      GenServer.stop(pid)
    end

    test "keeps the legacy version argument for pack_and_send/2" do
      {:ok, pid} =
        Router.start_link(
          %{
            system: 1,
            component: 100,
            dialect: Common,
            connection_strings: []
          },
          []
        )

      on_exit(fn ->
        if Process.whereis(XMAVLink.SubscriptionCache) do
          Agent.update(XMAVLink.SubscriptionCache, fn _ -> [] end)
        end
      end)

      assert :ok = Router.subscribe(message: Common.Message.Heartbeat, as_frame: true)

      msg = sample_heartbeat()

      assert :ok = Router.pack_and_send(msg, 1)

      assert_receive %XMAVLink.Frame{
                       source_system: 1,
                       source_component: 100,
                       version: 1
                     },
                     200

      Router.unsubscribe()
      GenServer.stop(pid)
    end
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

  defp open_udp_socket do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    {socket, port}
  end

  defp open_tcp_listener do
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
      spawn_link(fn ->
        case :gen_tcp.accept(listen_socket, 1_000) do
          {:ok, peer_socket} ->
            send(parent, :tcp_peer_accepted)

            receive do
              :close_tcp_peer -> :ok
            after
              1_000 -> :ok
            end

            :gen_tcp.close(peer_socket)

          other ->
            other
        end
      end)

    {listen_socket, acceptor, port}
  end

  defp open_tcp_reconnect_listener(accept_count) do
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
      spawn_link(fn ->
        for index <- 1..accept_count do
          case :gen_tcp.accept(listen_socket, 1_000) do
            {:ok, peer_socket} ->
              send(parent, {:tcp_peer_accepted, index})
              :gen_tcp.close(peer_socket)

            other ->
              send(parent, {:tcp_accept_failed, index, other})
          end
        end
      end)

    {listen_socket, acceptor, port}
  end

  defp close_tcp_listener(listen_socket, acceptor) do
    send(acceptor, :close_tcp_peer)
    :gen_tcp.close(listen_socket)
    :ok
  end

  defp close_tcp_reconnect_listener(listen_socket, acceptor) do
    :gen_tcp.close(listen_socket)
    Process.exit(acceptor, :kill)
    :ok
  end

  defp subscription_cache_name(XMAVLink.Router), do: XMAVLink.SubscriptionCache

  defp subscription_cache_name(router_name),
    do: {:global, {XMAVLink.Router, :subscription_cache, router_name}}

  defp stop_subscription_cache(router_name) do
    router_name
    |> subscription_cache_name()
    |> GenServer.whereis()
    |> case do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  end

  defp stop_router(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end
end
