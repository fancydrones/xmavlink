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

  defp create_systems_table do
    :ets.new(:systems, [:named_table, :protected, {:read_concurrency, true}, :ordered_set])
  end

  defp delete_table(table) do
    if :ets.info(table) != :undefined do
      :ets.delete(table)
    end
  end
end
