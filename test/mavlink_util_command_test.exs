defmodule XMAVLink.Util.CommandTest do
  use ExUnit.Case, async: false

  alias XMAVLink.Router
  alias XMAVLink.Util.Arm
  alias XMAVLink.Util.ParamRequest
  alias XMAVLink.Util.ParamSet
  alias XMAVLink.Util.SITL

  setup do
    delete_utility_tables()
    create_utility_tables()

    {:ok, router} =
      Router.start_link(%{
        name: nil,
        system: 245,
        component: 250,
        dialect: Common,
        connection_strings: []
      })

    on_exit(fn -> stop_router(router) end)

    {:ok, router: router}
  end

  test "param_set/6 times out and cleans up its subscription", %{router: router} do
    :ets.insert(
      :params,
      {{1, 1, "SYSID_THISMAV"},
       {0,
        %Common.Message.ParamValue{
          param_id: "SYSID_THISMAV",
          param_value: 1.0,
          param_count: 1,
          param_index: 0,
          param_type: :mav_param_type_real32
        }}}
    )

    assert {:error, :timeout} =
             ParamSet.param_set(1, 1, 2, "sysid_thismav", 2.0,
               router: router,
               retries: 0,
               retry_interval_ms: 1
             )

    assert_subscriptions(router, [])
  end

  test "param_request_list/4 times out instead of retrying forever", %{router: router} do
    :ets.insert(:systems, {{1, 1}, %{param_count: 0, param_count_loaded: 0}})

    assert {:error, :timeout} =
             ParamRequest.param_request_list(1, 1, 2,
               router: router,
               retries: 0,
               retry_interval_ms: 1
             )
  end

  test "arm/4 times out and cleans up its subscription", %{router: router} do
    :ets.insert(
      :messages,
      {{1, 1, Common.Message.Heartbeat}, {0, heartbeat(:mav_state_standby, MapSet.new())}}
    )

    assert {:error, :timeout} =
             Arm.arm(1, 1, 2,
               router: router,
               retries: 0,
               retry_interval_ms: 1
             )

    assert_subscriptions(router, [])
  end

  test "SITL RC forwarding rejects invalid destination addresses", %{router: router} do
    assert {:error, :invalid_destination_address} =
             SITL._connect(1, 1, 2, 5501, router, %{bad: :address})

    assert {:error, :invalid_destination_address} =
             SITL._connect(1, 1, 2, 5501, router, {127, 0, 0, 999})
  end

  defp assert_subscriptions(router, subscriptions, attempts \\ 20)

  defp assert_subscriptions(router, subscriptions, attempts) when attempts > 0 do
    state = :sys.get_state(router)

    if state.connections.local.subscriptions == subscriptions do
      :ok
    else
      Process.sleep(10)
      assert_subscriptions(router, subscriptions, attempts - 1)
    end
  end

  defp assert_subscriptions(router, subscriptions, 0) do
    state = :sys.get_state(router)
    assert state.connections.local.subscriptions == subscriptions
  end

  defp heartbeat(system_status, base_mode) do
    %Common.Message.Heartbeat{
      type: :mav_type_quadrotor,
      autopilot: :mav_autopilot_ardupilotmega,
      base_mode: base_mode,
      custom_mode: 0,
      system_status: system_status,
      mavlink_version: 3
    }
  end

  defp create_utility_tables do
    :ets.new(:messages, [:named_table, :protected, {:read_concurrency, true}, :set])
    :ets.new(:systems, [:named_table, :protected, {:read_concurrency, true}, :ordered_set])
    :ets.new(:params, [:named_table, :protected, {:read_concurrency, true}, :ordered_set])
  end

  defp delete_utility_tables do
    for table <- [:messages, :systems, :params, :sessions], :ets.info(table) != :undefined do
      :ets.delete(table)
    end
  end

  defp stop_router(router) do
    if Process.alive?(router) do
      GenServer.stop(router)
    end
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end
end
