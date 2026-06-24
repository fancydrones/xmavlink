defmodule XMAVLink.Util.Tables do
  @moduledoc false

  @kinds [:messages, :systems, :params, :sessions]

  def names(opts_or_prefix \\ []) do
    prefix = prefix(opts_or_prefix)

    Map.new(@kinds, fn kind ->
      {kind, table_name(kind, prefix)}
    end)
  end

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
