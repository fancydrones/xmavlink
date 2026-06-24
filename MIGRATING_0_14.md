# Migrating to XMAVLink 0.14.0

XMAVLink 0.14.0 keeps the core router API stable while making the utility
runtime explicit and easier to scope.

## What Stayed Stable

Applications using the router API should not need source changes for normal
send and subscribe flows:

```elixir
XMAVLink.Router.subscribe(message: Common.Message.Heartbeat)
XMAVLink.Router.pack_and_send(heartbeat, 2)
```

Named routers also continue to work:

```elixir
XMAVLink.Router.subscribe(MyApp.VehicleRouter, message: Common.Message.Heartbeat)
XMAVLink.Router.pack_and_send(MyApp.VehicleRouter, message, 2)
```

## Utility Contexts

Utility helpers now accept `context: context` when an application needs an
explicit router, dialect, or ETS table namespace.

```elixir
context =
  XMAVLink.Util.Context.new(
    router: MyApp.VehicleRouter,
    dialect: Common,
    table_prefix: :vehicle_a
  )

XMAVLink.Util.CacheManager.list_systems(context: context)
XMAVLink.Util.CacheManager.latest_message(1, 1, Common.Message.Heartbeat, context: context)
XMAVLink.Util.ParamSet.param_set(1, 1, 2, "SYSID_THISMAV", 2.0, context: context)
```

The default context still uses the configured `:xmavlink` router and dialect,
with the historical table names `:messages`, `:systems`, `:params`, and
`:sessions`.

## Replace Direct ETS Reads

Prefer public utility APIs over direct ETS access. Direct table reads couple an
application to internal cache layout and make scoped utility contexts harder to
adopt.

Before:

```elixir
:ets.lookup(:params, {1, 1, "SYSID_THISMAV"})
```

After:

```elixir
XMAVLink.Util.CacheManager.get_param(1, 1, "SYSID_THISMAV")
```

For scoped utility state:

```elixir
XMAVLink.Util.CacheManager.get_param(1, 1, "SYSID_THISMAV", context: context)
```

The public cache query helpers are:

- `XMAVLink.Util.CacheManager.list_systems/0` and `/1`
- `XMAVLink.Util.CacheManager.latest_message/3` and `/4`
- `XMAVLink.Util.CacheManager.get_param/3` and `/4`

If an integration truly needs table names for supervision or migration code,
use `XMAVLink.Util.Tables` instead of hard-coding names:

```elixir
XMAVLink.Util.Tables.name(:params, context: context)
XMAVLink.Util.Tables.names(context: context)
```

## Utility Supervision

When supervising utilities explicitly, pass the same context used by callers:

```elixir
children = [
  {XMAVLink.Router,
   %{
     name: MyApp.VehicleRouter,
     system: 245,
     component: 250,
     dialect: Common,
     connection_strings: ["udpout:127.0.0.1:14550"]
   }},
  {XMAVLink.Util.Supervisor, context: context, auto_param_request: false}
]
```

Use `auto_param_request: false` on less trusted networks and request
parameters deliberately after deciding a vehicle should be queried.

## New Send API

`XMAVLink.Router.send_message/1..3` is the structured alternative to
`pack_and_send/2..4`. It returns delivery metadata instead of only `:ok`.

```elixir
{:ok, delivery} =
  XMAVLink.Router.send_message(
    MyApp.VehicleRouter,
    %Common.Message.Ping{
      time_usec: 0,
      seq: 1,
      target_system: 42,
      target_component: 1
    },
    version: 2
  )

delivery.unreachable?
delivery.recipients
```

Existing `pack_and_send` calls remain supported.
