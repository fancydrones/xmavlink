defmodule XMAVLink.Util.FocusManager.Test do
  use ExUnit.Case

  alias XMAVLink.Util.FocusManager

  setup do
    delete_table(:sessions)
    delete_table(:systems)
    create_systems_table()
    start_supervised!(FocusManager)

    on_exit(fn ->
      delete_table(:sessions)
      delete_table(:systems)
    end)

    :ok
  end

  test "focus/2 stores focus for caller" do
    :ets.insert(:systems, {{1, 1}, %{mavlink_major_version: 2}})

    assert :ok = FocusManager.focus(1, 1)
    assert {:ok, {1, 1, 2}} = FocusManager.focus()
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
    :ets.new(:systems, [:named_table, :protected, {:read_concurrency, true}, :ordered_set])
  end

  defp delete_table(table) do
    if :ets.info(table) != :undefined do
      :ets.delete(table)
    end
  end
end
