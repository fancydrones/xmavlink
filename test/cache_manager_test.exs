defmodule XMAVLink.Util.CacheManager.Test do
  use ExUnit.Case

  alias XMAVLink.Util.CacheManager

  setup do
    delete_utility_tables()
    create_systems_table()
    create_params_table()

    :ok
  end

  test "mavs/0 returns visible system/component ids" do
    :ets.insert(:systems, {{1, 1}, %{}})
    :ets.insert(:systems, {{2, 1}, %{}})

    assert {:ok, mavs} = CacheManager.mavs()
    assert Enum.sort(mavs) == [{1, 1}, {2, 1}]
  end

  test "params/2 returns MAVLink parameter names as string keys" do
    :ets.insert(
      :params,
      {{1, 1, "SYSID_THISMAV"},
       {0,
        %Common.Message.ParamValue{
          param_id: "SYSID_THISMAV",
          param_value: 42.0,
          param_count: 1,
          param_index: 0,
          param_type: :mav_param_type_real32
        }}}
    )

    assert {:ok, params} = CacheManager.params({1, 1, 2}, "SYSID")
    assert params == %{"SYSID_THISMAV" => 42.0}
    refute Map.has_key?(params, :sysid_thismav)
  end

  test "msg/2 preserves not-started errors" do
    assert {:error, :not_started} = CacheManager.msg({1, 1, 2}, Common.Message.Heartbeat)
  end

  test "params/2 preserves not-started errors" do
    delete_table(:params)

    assert {:error, :not_started} = CacheManager.params({1, 1, 2}, "")
  end

  test "does not request parameters for a first heartbeat when auto_param_request is disabled" do
    create_messages_table()

    heartbeat = %Common.Message.Heartbeat{
      type: :mav_type_quadrotor,
      autopilot: :mav_autopilot_ardupilotmega,
      base_mode: MapSet.new(),
      custom_mode: 0,
      system_status: :mav_state_active,
      mavlink_version: 3
    }

    frame = %XMAVLink.Frame{
      message: heartbeat,
      source_system: 1,
      source_component: 1,
      version: 2
    }

    state = %CacheManager{router: XMAVLink.Router, auto_param_request: false}

    assert {:noreply, ^state} = CacheManager.handle_info(frame, state)

    assert [
             {{1, 1},
              %{
                mavlink_major_version: 2,
                mavlink_minor_version: 3,
                param_count: 0,
                param_count_loaded: 0
              }}
           ] = :ets.lookup(:systems, {1, 1})
  end

  test "one second loop reschedules one second loop" do
    state = %CacheManager{one_second_interval_ms: 1}

    assert {:noreply, ^state} = CacheManager.handle_info(:one_second_loop, state)
    assert_receive :one_second_loop, 50
  end

  test "five second loop reschedules five second loop" do
    state = %CacheManager{five_second_interval_ms: 1}

    assert {:noreply, ^state} = CacheManager.handle_info(:five_second_loop, state)
    assert_receive :five_second_loop, 50
    refute_received :one_second_loop
  end

  test "ten second loop reschedules ten second loop" do
    state = %CacheManager{ten_second_interval_ms: 1}

    assert {:noreply, ^state} = CacheManager.handle_info(:ten_second_loop, state)
    assert_receive :ten_second_loop, 50
    refute_received :one_second_loop
  end

  defp create_systems_table do
    :ets.new(:systems, [:named_table, :protected, {:read_concurrency, true}, :ordered_set])
  end

  defp create_messages_table do
    :ets.new(:messages, [:named_table, :protected, {:read_concurrency, true}, :set])
  end

  defp create_params_table do
    :ets.new(:params, [:named_table, :protected, {:read_concurrency, true}, :ordered_set])
  end

  defp delete_utility_tables do
    delete_table(:messages)
    delete_table(:systems)
    delete_table(:params)
    delete_table(:sessions)
  end

  defp delete_table(table) do
    if :ets.info(table) != :undefined do
      :ets.delete(table)
    end
  end
end
