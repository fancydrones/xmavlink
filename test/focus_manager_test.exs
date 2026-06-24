defmodule XMAVLink.Util.FocusManager.Test do
  use ExUnit.Case

  alias XMAVLink.Util.FocusManager
  alias XMAVLink.Util.Context

  setup do
    delete_table(:sessions)
    delete_table(:systems)
    create_systems_table()
    start_supervised!(FocusManager)

    :ok
  end

  test "focus/2 stores focus for caller" do
    :ets.insert(:systems, {{1, 1}, %{mavlink_major_version: 2}})

    assert :ok = FocusManager.focus(1, 1)
    assert {:ok, {1, 1, 2}} = FocusManager.focus()
  end

  test "focus/2 returns an error when the vehicle does not exist" do
    assert {:error, :no_such_mav} = FocusManager.focus(1, 1)
  end

  test "focus/2 returns an error when utility state has not been started" do
    delete_table(:systems)

    assert {:error, :not_started} = FocusManager.focus(1, 1)
  end

  test "focus sessions are removed when the owner process exits" do
    :ets.insert(:systems, {{1, 1}, %{mavlink_major_version: 2}})
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:focused, self(), FocusManager.focus(1, 1)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:focused, ^pid, :ok}
    assert {:ok, {1, 1, 2}} = FocusManager.focus(pid)

    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    assert_focus_cleared(pid)
  end

  test "focus can be scoped to a utility context" do
    first_context = Context.new(table_prefix: :vehicle_a)
    second_context = Context.new(table_prefix: :vehicle_b)
    delete_tables(Map.values(first_context.tables))
    delete_tables(Map.values(second_context.tables))
    create_systems_table(first_context.tables.systems)
    create_systems_table(second_context.tables.systems)
    create_sessions_table(first_context.tables.sessions)
    create_sessions_table(second_context.tables.sessions)

    on_exit(fn ->
      delete_tables(Map.values(first_context.tables))
      delete_tables(Map.values(second_context.tables))
    end)

    :ets.insert(first_context.tables.systems, {{2, 1}, %{mavlink_major_version: 2}})
    :ets.insert(second_context.tables.systems, {{3, 1}, %{mavlink_major_version: 2}})

    assert :ok = FocusManager.focus(2, 1, context: first_context)
    assert :ok = FocusManager.focus(3, 1, context: second_context)
    assert {:ok, {2, 1, 2}} = FocusManager.focus(context: first_context)
    assert {:ok, {3, 1, 2}} = FocusManager.focus(context: second_context)
    assert {:error, :not_focussed} = FocusManager.focus()
  end

  defp assert_focus_cleared(pid, attempts \\ 20)

  defp assert_focus_cleared(pid, attempts) when attempts > 0 do
    case FocusManager.focus(pid) do
      {:error, :not_focussed} ->
        :ok

      {:ok, _} ->
        Process.sleep(10)
        assert_focus_cleared(pid, attempts - 1)
    end
  end

  defp assert_focus_cleared(pid, 0) do
    flunk("expected focus session for #{inspect(pid)} to be removed")
  end

  defp create_systems_table do
    create_systems_table(:systems)
  end

  defp create_systems_table(table) do
    :ets.new(table, [:named_table, :protected, {:read_concurrency, true}, :ordered_set])
  end

  defp create_sessions_table(table) do
    :ets.new(table, [:named_table, :public, {:read_concurrency, true}, :set])
  end

  defp delete_tables(tables), do: Enum.each(tables, &delete_table/1)

  defp delete_table(table) do
    if :ets.info(table) != :undefined do
      :ets.delete(table)
    end
  end
end
