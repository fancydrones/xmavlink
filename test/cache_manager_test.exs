defmodule XMAVLink.Util.CacheManager.Test do
  use ExUnit.Case

  alias XMAVLink.Util.CacheManager

  setup do
    delete_table(:systems)
    create_systems_table()

    on_exit(fn ->
      delete_table(:systems)
    end)

    :ok
  end

  test "mavs/0 returns visible system/component ids" do
    :ets.insert(:systems, {{1, 1}, %{}})
    :ets.insert(:systems, {{2, 1}, %{}})

    assert {:ok, mavs} = CacheManager.mavs()
    assert Enum.sort(mavs) == [{1, 1}, {2, 1}]
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

  defp delete_table(table) do
    if :ets.info(table) != :undefined do
      :ets.delete(table)
    end
  end
end
