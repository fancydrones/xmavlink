defmodule XMAVLink.Util.CacheManager.Test do
  use ExUnit.Case

  alias XMAVLink.Util.Cache.Message, as: CachedMessage
  alias XMAVLink.Util.Cache.Param, as: CachedParam
  alias XMAVLink.Util.Cache.System, as: CachedSystem
  alias XMAVLink.Util.CacheManager
  alias XMAVLink.Util.Context

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

  test "list_systems/1 returns cached system metadata" do
    first =
      CachedSystem.new(%{
        mavlink_major_version: 2,
        mavlink_minor_version: 3,
        param_count: 4,
        param_count_loaded: 2
      })

    second =
      CachedSystem.new(%{
        mavlink_major_version: 1,
        mavlink_minor_version: 0,
        param_count: 0,
        param_count_loaded: 0
      })

    :ets.insert(:systems, {{2, 1}, second})
    :ets.insert(:systems, {{1, 1}, first})

    assert {:ok, [{{1, 1}, ^first}, {{2, 1}, ^second}]} = CacheManager.list_systems()
  end

  test "latest_message/4 returns cached message age and struct" do
    create_messages_table()

    heartbeat = %Common.Message.Heartbeat{
      type: :mav_type_quadrotor,
      autopilot: :mav_autopilot_ardupilotmega,
      base_mode: MapSet.new(),
      custom_mode: 0,
      system_status: :mav_state_active,
      mavlink_version: 3
    }

    received_at = :erlang.monotonic_time(:milli_seconds) - 10

    :ets.insert(
      :messages,
      {{1, 1, Common.Message.Heartbeat}, CachedMessage.new(heartbeat, received_at)}
    )

    assert {:ok, age_ms, ^heartbeat} = CacheManager.latest_message(1, 1, Common.Message.Heartbeat)
    assert age_ms >= 0
  end

  test "params/2 returns MAVLink parameter names as string keys" do
    :ets.insert(
      :params,
      {{1, 1, "SYSID_THISMAV"},
       CachedParam.new(
         %Common.Message.ParamValue{
           param_id: "SYSID_THISMAV",
           param_value: 42.0,
           param_count: 1,
           param_index: 0,
           param_type: :mav_param_type_real32
         },
         0
       )}
    )

    assert {:ok, params} = CacheManager.params({1, 1, 2}, "SYSID")
    assert params == %{"SYSID_THISMAV" => 42.0}
    refute Map.has_key?(params, :sysid_thismav)
  end

  test "get_param/4 returns one cached parameter message" do
    param = %Common.Message.ParamValue{
      param_id: "SYSID_THISMAV",
      param_value: 42.0,
      param_count: 1,
      param_index: 0,
      param_type: :mav_param_type_real32
    }

    received_at = :erlang.monotonic_time(:milli_seconds) - 10
    :ets.insert(:params, {{1, 1, "SYSID_THISMAV"}, CachedParam.new(param, received_at)})

    assert {:ok, age_ms, ^param} = CacheManager.get_param(1, 1, :sysid_thismav)
    assert age_ms >= 0
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
              %CachedSystem{
                mavlink_major_version: 2,
                mavlink_minor_version: 3,
                param_count: 0,
                param_count_loaded: 0
              }}
           ] = :ets.lookup(:systems, {1, 1})
  end

  test "caches and reads messages from prefixed utility tables" do
    context = Context.new(router: XMAVLink.Router, dialect: Common, table_prefix: :vehicle_a)
    tables = context.tables
    delete_tables(Map.values(tables))
    create_utility_tables(tables)

    on_exit(fn -> delete_tables(Map.values(tables)) end)

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

    state = %CacheManager{
      context: context,
      router: context.router,
      auto_param_request: false,
      dialect: context.dialect,
      table_prefix: context.table_prefix,
      tables: context.tables
    }

    assert {:noreply, ^state} = CacheManager.handle_info(frame, state)

    assert [
             {{1, 1},
              %CachedSystem{
                mavlink_major_version: 2,
                mavlink_minor_version: 3,
                param_count: 0,
                param_count_loaded: 0
              }}
           ] = :ets.lookup(tables.systems, {1, 1})

    assert {:ok, [{1, 1}]} = CacheManager.mavs(context: context)

    assert {:ok, [{{1, 1}, %CachedSystem{mavlink_major_version: 2}}]} =
             CacheManager.list_systems(context: context)

    assert {:ok, _age_ms, ^heartbeat} =
             CacheManager.latest_message(1, 1, Common.Message.Heartbeat, context: context)
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

  defp create_utility_tables(tables) do
    :ets.new(tables.messages, [:named_table, :protected, {:read_concurrency, true}, :set])
    :ets.new(tables.systems, [:named_table, :protected, {:read_concurrency, true}, :ordered_set])
    :ets.new(tables.params, [:named_table, :protected, {:read_concurrency, true}, :ordered_set])
    :ets.new(tables.sessions, [:named_table, :protected, {:read_concurrency, true}, :set])
  end

  defp delete_utility_tables do
    delete_table(:messages)
    delete_table(:systems)
    delete_table(:params)
    delete_table(:sessions)
  end

  defp delete_tables(tables), do: Enum.each(tables, &delete_table/1)

  defp delete_table(table) do
    if :ets.info(table) != :undefined do
      :ets.delete(table)
    end
  end
end
