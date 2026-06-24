defmodule XMAVLink.Util.Context do
  @moduledoc """
  Utility-layer runtime context.

  Utility helpers use this context to choose the router, dialect, and ETS table
  namespace they operate on. Pass `context: context` to utility functions when
  an application has more than one MAVLink runtime or when global ETS table
  names are not acceptable.
  """

  alias XMAVLink.Util.{Defaults, Tables}

  @type table_prefix :: atom | String.t() | nil

  @type t :: %__MODULE__{
          router: GenServer.server(),
          dialect: module,
          table_prefix: table_prefix,
          tables: %{required(atom) => atom}
        }

  defstruct router: nil,
            dialect: nil,
            table_prefix: nil,
            tables: Tables.names()

  @spec new(keyword | map | t) :: t
  def new(opts \\ [])

  def new(context = %__MODULE__{}) do
    %__MODULE__{
      context
      | router: context.router || configured_router(),
        dialect: context.dialect || configured_dialect(),
        tables: Tables.names(context.table_prefix)
    }
  end

  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(opts) when is_map(opts) do
    base = base_context(Map.get(opts, :context))

    router = Map.get(opts, :router, base.router || configured_router())
    dialect = Map.get(opts, :dialect, base.dialect || configured_dialect())
    table_prefix = Map.get(opts, :table_prefix, base.table_prefix)

    %__MODULE__{
      router: router,
      dialect: dialect,
      table_prefix: table_prefix,
      tables: Tables.names(table_prefix)
    }
  end

  defp base_context(nil), do: %__MODULE__{}
  defp base_context(context), do: new(context)

  defp configured_router do
    Application.get_env(:xmavlink, :router_name, XMAVLink.Router) || XMAVLink.Router
  end

  defp configured_dialect do
    Application.get_env(:xmavlink, :dialect, Defaults.default_dialect()) ||
      Defaults.default_dialect()
  end
end
