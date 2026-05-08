defmodule XMAVLink.ApplicationTest do
  use ExUnit.Case, async: false

  test "starts utility processes when utilities are enabled" do
    previous_env =
      save_env([:dialect, :router_name, :connections, :utilities, :heartbeat, :heartbeats])

    Application.put_env(:xmavlink, :dialect, Common)
    Application.put_env(:xmavlink, :router_name, XMAVLink.Router)
    Application.put_env(:xmavlink, :connections, [])
    Application.put_env(:xmavlink, :utilities, true)
    Application.delete_env(:xmavlink, :heartbeat)
    Application.delete_env(:xmavlink, :heartbeats)

    assert {:ok, supervisor} = XMAVLink.Application.start(:normal, [])

    on_exit(fn ->
      stop_supervisor(supervisor)
      cleanup_process(XMAVLink.SubscriptionCache)
      delete_utility_tables()
      restore_env(previous_env)
    end)

    assert Process.whereis(XMAVLink.Util.Supervisor)
    assert Process.whereis(XMAVLink.Util.CacheManager)
    assert Process.whereis(XMAVLink.Util.FocusManager)
    assert XMAVLink.Util.CacheManager.router() == XMAVLink.Router
  end

  test "passes utility options to utility processes" do
    previous_env =
      save_env([:dialect, :router_name, :connections, :utilities, :heartbeat, :heartbeats])

    Application.put_env(:xmavlink, :dialect, Common)
    Application.put_env(:xmavlink, :router_name, XMAVLink.Router)
    Application.put_env(:xmavlink, :connections, [])
    Application.put_env(:xmavlink, :utilities, auto_param_request: false)
    Application.delete_env(:xmavlink, :heartbeat)
    Application.delete_env(:xmavlink, :heartbeats)

    assert {:ok, supervisor} = XMAVLink.Application.start(:normal, [])

    on_exit(fn ->
      stop_supervisor(supervisor)
      cleanup_process(XMAVLink.SubscriptionCache)
      delete_utility_tables()
      restore_env(previous_env)
    end)

    cache_manager = Process.whereis(XMAVLink.Util.CacheManager)
    assert %XMAVLink.Util.CacheManager{auto_param_request: false} = :sys.get_state(cache_manager)
  end

  test "rejects invalid utility options with a clear error" do
    previous_env =
      save_env([:dialect, :router_name, :connections, :utilities, :heartbeat, :heartbeats])

    Application.put_env(:xmavlink, :dialect, Common)
    Application.put_env(:xmavlink, :router_name, XMAVLink.Router)
    Application.put_env(:xmavlink, :connections, [])
    Application.put_env(:xmavlink, :utilities, [:auto_param_request])
    Application.delete_env(:xmavlink, :heartbeat)
    Application.delete_env(:xmavlink, :heartbeats)

    on_exit(fn ->
      cleanup_process(XMAVLink.SubscriptionCache)
      delete_utility_tables()
      restore_env(previous_env)
    end)

    assert_raise ArgumentError, ~r/:utilities must be true, false, nil, or a keyword list/, fn ->
      XMAVLink.Application.start(:normal, [])
    end
  end

  defp save_env(keys) do
    Map.new(keys, &{&1, Application.fetch_env(:xmavlink, &1)})
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, {:ok, value}} -> Application.put_env(:xmavlink, key, value)
      {key, :error} -> Application.delete_env(:xmavlink, key)
    end)
  end

  defp stop_supervisor(supervisor) do
    if Process.alive?(supervisor) do
      Supervisor.stop(supervisor)
    end
  catch
    :exit, _ -> :ok
  end

  defp cleanup_process(name) do
    if pid = Process.whereis(name), do: Process.exit(pid, :kill)
  end

  defp delete_utility_tables do
    for table <- [:messages, :systems, :params, :sessions], :ets.info(table) != :undefined do
      :ets.delete(table)
    end
  end
end
