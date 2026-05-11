defmodule XMAVLink.SupervisorTest do
  use ExUnit.Case, async: false

  test "falls back to the default router name when app config sets router_name to nil" do
    previous_router_name = Application.get_env(:xmavlink, :router_name)
    previous_heartbeat = Application.get_env(:xmavlink, :heartbeat)
    previous_connection_retry_ms = Application.get_env(:xmavlink, :connection_retry_ms)
    previous_remote_forwarding = Application.get_env(:xmavlink, :remote_forwarding)

    Application.put_env(:xmavlink, :router_name, nil)
    Application.put_env(:xmavlink, :connection_retry_ms, 250)
    Application.put_env(:xmavlink, :remote_forwarding, false)
    Application.put_env(:xmavlink, :heartbeat, interval_ms: 1000, message: sample_heartbeat())

    on_exit(fn ->
      restore_env(:router_name, previous_router_name)
      restore_env(:heartbeat, previous_heartbeat)
      restore_env(:connection_retry_ms, previous_connection_retry_ms)
      restore_env(:remote_forwarding, previous_remote_forwarding)
    end)

    assert {:ok, {_supervisor_flags, children}} = XMAVLink.Supervisor.init([])

    assert %{
             start:
               {XMAVLink.Router, :start_link,
                [%{name: XMAVLink.Router, connection_retry_ms: 250, remote_forwarding: false}]}
           } =
             Enum.find(children, &match?(%{id: XMAVLink.Router}, &1))

    assert %{start: {XMAVLink.Heartbeat, :start_link, [heartbeat_spec]}} =
             Enum.find(children, &match?(%{id: {XMAVLink.Heartbeat, 0}}, &1))

    assert Keyword.fetch!(heartbeat_spec, :router) == XMAVLink.Router
  end

  defp restore_env(key, nil), do: Application.delete_env(:xmavlink, key)
  defp restore_env(key, value), do: Application.put_env(:xmavlink, key, value)

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
end
