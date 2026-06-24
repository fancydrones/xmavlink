defmodule XMAVLink.Util.ContextTest do
  use ExUnit.Case

  alias XMAVLink.Util.Context
  alias XMAVLink.Util.Tables

  test "new/1 normalizes router dialect and prefixed table names" do
    context =
      Context.new(
        router: XMAVLink.Test.Router,
        dialect: Common,
        table_prefix: :vehicle_a
      )

    assert context.router == XMAVLink.Test.Router
    assert context.dialect == Common
    assert context.table_prefix == :vehicle_a

    assert context.tables == %{
             messages: :vehicle_a_messages,
             systems: :vehicle_a_systems,
             params: :vehicle_a_params,
             sessions: :vehicle_a_sessions
           }
  end

  test "new/1 allows explicit options to override a base context" do
    base =
      Context.new(
        router: XMAVLink.Test.RouterA,
        dialect: Common,
        table_prefix: :vehicle_a
      )

    context = Context.new(context: base, router: XMAVLink.Test.RouterB, table_prefix: :vehicle_b)

    assert context.router == XMAVLink.Test.RouterB
    assert context.dialect == Common
    assert context.table_prefix == :vehicle_b
    assert context.tables.messages == :vehicle_b_messages
  end

  test "tables helper accepts context options" do
    context = Context.new(table_prefix: :vehicle_a)

    assert Tables.name(:systems, context: context) == :vehicle_a_systems
    assert Tables.names(context: context).params == :vehicle_a_params
  end
end
