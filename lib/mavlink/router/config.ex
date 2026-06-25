defmodule XMAVLink.Router.Config do
  @moduledoc false

  alias XMAVLink.Signing

  @type router_name :: XMAVLink.Router.router_name()

  @spec from_application_env() :: map
  def from_application_env do
    router_name = Application.get_env(:xmavlink, :router_name, XMAVLink.Router) || XMAVLink.Router

    normalize!(%{
      name: router_name,
      dialect: Application.get_env(:xmavlink, :dialect),
      system: Application.get_env(:xmavlink, :system_id),
      component: Application.get_env(:xmavlink, :component_id),
      connection_strings: Application.get_env(:xmavlink, :connections),
      connection_retry_ms: Application.get_env(:xmavlink, :connection_retry_ms, 1_000),
      remote_forwarding: Application.get_env(:xmavlink, :remote_forwarding, true),
      forward_unknown: Application.get_env(:xmavlink, :forward_unknown, :broadcast),
      signing: Application.get_env(:xmavlink, :signing)
    })
  end

  @spec normalize!(map | keyword) :: map
  def normalize!(args) do
    args = Map.new(args)
    connection_strings = Map.get(args, :connection_strings, Map.get(args, :connections, [])) || []
    connection_retry_ms = Map.get(args, :connection_retry_ms, 1_000)
    remote_forwarding = Map.get(args, :remote_forwarding, true)
    forward_unknown = Map.get(args, :forward_unknown, :broadcast)
    signing = normalize_signing!(Map.get(args, :signing))

    if not (is_integer(connection_retry_ms) and connection_retry_ms >= 0) do
      raise ArgumentError, "connection_retry_ms must be a non-negative integer"
    end

    if not is_boolean(remote_forwarding) do
      raise ArgumentError, "remote_forwarding must be a boolean"
    end

    if forward_unknown not in [:broadcast, :local_only, :drop] do
      raise ArgumentError, "forward_unknown must be one of :broadcast, :local_only, or :drop"
    end

    args
    |> Map.put(:connection_strings, connection_strings)
    |> Map.put(:connection_retry_ms, connection_retry_ms)
    |> Map.put(:remote_forwarding, remote_forwarding)
    |> Map.put(:forward_unknown, forward_unknown)
    |> Map.put(:signing, signing)
  end

  defp normalize_signing!(signing) do
    case Signing.new(signing) do
      {:ok, signing} -> signing
      {:error, reason} -> raise ArgumentError, "invalid signing config: #{inspect(reason)}"
    end
  end
end
