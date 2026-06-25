defmodule XMAVLink.Util.Command do
  @moduledoc false

  alias XMAVLink.Util.CacheManager
  alias XMAVLink.Util.Context

  def opts(source_opts, retry_interval_ms, retries) do
    context =
      source_opts |> Keyword.put(:router, CacheManager.router(source_opts)) |> Context.new()

    retries = Keyword.get(source_opts, :retries, retries)

    %{
      context: context,
      router: context.router,
      dialect: context.dialect,
      table_prefix: context.table_prefix,
      retry_interval_ms: Keyword.get(source_opts, :retry_interval_ms, retry_interval_ms),
      attempts: attempts(retries),
      source_opts: source_opts
    }
  end

  def attempts(:infinity), do: :infinity
  def attempts(retries) when is_integer(retries) and retries >= 0, do: retries + 1

  def next_attempts(:infinity), do: :infinity
  def next_attempts(attempts), do: attempts - 1

  def require_table(table) do
    case :ets.info(table) do
      :undefined -> {:error, :not_started}
      _ -> :ok
    end
  end

  def message_module(dialect, name), do: Module.concat([dialect, Message, name])

  def describe(dialect, value) do
    if function_exported?(dialect, :describe, 1) do
      apply(dialect, :describe, [value])
    else
      inspect(value)
    end
  end
end
