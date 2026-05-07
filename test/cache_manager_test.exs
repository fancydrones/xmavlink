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
