defmodule XMAVLink.Util.Tables do
  @moduledoc """
  Utility ETS table name helpers.

  Most applications should use `XMAVLink.Util.CacheManager` query functions
  instead of reading ETS tables directly. When an integration needs table names
  for supervision or migration code, use this module rather than hard-coding
  global names such as `:messages`, `:systems`, `:params`, and `:sessions`.
  """

  @kinds [:messages, :systems, :params, :sessions]

  @type kind :: :messages | :systems | :params | :sessions
  @type prefix :: atom | String.t() | nil
  @type opts_or_prefix ::
          keyword | %{optional(:table_prefix) => prefix} | XMAVLink.Util.Context.t() | prefix

  @doc """
  Return all utility table names for a context, prefix, or options.
  """
  @spec names(opts_or_prefix) :: %{required(kind) => atom}
  def names(opts_or_prefix \\ []) do
    prefix = prefix(opts_or_prefix)

    Map.new(@kinds, fn kind ->
      {kind, table_name(kind, prefix)}
    end)
  end

  @doc """
  Return one utility table name for a context, prefix, or options.
  """
  @spec name(kind, opts_or_prefix) :: atom
  def name(kind, opts_or_prefix \\ []) when kind in @kinds do
    table_name(kind, prefix(opts_or_prefix))
  end

  defp table_name(kind, nil), do: kind
  defp table_name(kind, prefix), do: :"#{prefix}_#{kind}"

  defp prefix(opts) when is_list(opts) do
    case Keyword.fetch(opts, :context) do
      {:ok, %{table_prefix: prefix}} -> Keyword.get(opts, :table_prefix, prefix)
      :error -> Keyword.get(opts, :table_prefix)
    end
  end

  defp prefix(%{table_prefix: prefix}), do: prefix
  defp prefix(nil), do: nil
  defp prefix(prefix) when is_atom(prefix) or is_binary(prefix), do: prefix
end
