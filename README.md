# XMAVLink

This library includes a mix task that generates code from MAVLink XML
definition files and an application that enables communication with other
systems using MAVLink 1 frames, unsigned MAVLink 2 frames, and configured
signed MAVLink 2 frames over serial, UDP, and outbound TCP connections.

MAVLink is a Micro Air Vehicle communication protocol used by Pixhawk,
ArduPilot and other leading autopilot platforms. For more information
on MAVLink see https://mavlink.io.

## Installation

XMAVLink currently supports Elixir 1.18 and later on Erlang/OTP 27 and later.
CI tests the pinned repository toolchain in `.tool-versions` and a newer
Elixir/OTP line.

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `xmavlink` to your list of dependencies in `mix.exs`:

  ```elixir
 def deps do
   [
     {:xmavlink, "~> 0.14.2"}
   ]
 end
 ```

## Publishing

Hex publishing is automated through GitHub Actions after changes are merged to
`main`. The publish job runs only when the package `version` in `mix.exs`
changes from the previous `main` revision, waits for the normal CI and Dialyzer
jobs to pass, skips reruns when the same version already exists on Hex, and then
runs `mix hex.publish --yes`.

To enable publishing, configure a `HEX_API_KEY` secret on the `hex-publish`
GitHub Actions environment with a Hex API key that can publish the `xmavlink`
package. With Hex 2.4 and later, create the key from the hex.pm web dashboard
rather than `mix hex.user key generate`; the CLI now uses browser-based OAuth
for local authentication. Enable 2FA on the publishing Hex account first,
create a package-scoped key for `xmavlink` if the dashboard offers that scope
(`package:xmavlink` in the older CLI permission naming), then store the key only
on the `hex-publish` environment. If a package-scoped key is not available,
`api:write` is the broader fallback Hex documents for CI publishing.

## Current Status

This library is not officially recognised or supported by MAVLink at this
time.

XMAVLink parses and emits MAVLink 1 frames and unsigned MAVLink 2 frames.
Router-level MAVLink 2 signing can be configured with a 32-byte key, link id,
and local timestamp. Signed inbound frames are verified before unpacking, replay
timestamps are tracked per connection, and unsigned MAVLink 2 inbound frames are
rejected by default while signing is enabled unless `accept_unsigned: true` is
set. Unsigned outbound MAVLink 2 frames sent over a signing-enabled connection
are signed with a monotonically incremented per-connection timestamp. MAVLink 1
inbound and outbound frames remain unsigned and accepted under a signing policy.
Applications can configure timestamp load/save callbacks to preserve local
signing timestamps across restarts. Inbound `SETUP_SIGNING` frames are delivered
locally but are not forwarded between MAVLink links by generic routing. MAVLink
2 frames with other incompatible flags are discarded. Supported configured
transports are serial, UDP client (`udpout`), UDP server (`udpin`), and TCP
client (`tcpout`). TCP server (`tcpin`) connections are not implemented.

MAVLink 2 is the primary 1.0 compatibility target. MAVLink 1 remains supported
for existing frame parsing, packing, and routing behavior while that support
stays cheap to maintain, but new MAVLink 1-only work may be declined or moved
out of scope if it competes with MAVLink 2 correctness. The 1.0 spec alignment
checklist is maintained in [MAVLINK_SPEC_ALIGNMENT.md](MAVLINK_SPEC_ALIGNMENT.md).

## Generating MAVLink Dialect Modules

MAVLink message definition files for popular dialects can be found [here](https://github.com/mavlink/mavlink/tree/master/message_definitions/v1.0).
To generate an Elixir source file containing the modules we need to speak a MAVLink dialect (for example ardupilotmega):

```
> mix xmavlink test/input/ardupilotmega.xml lib/apm.ex APM
* creating lib/apm.ex
Generated APM in 'lib/apm.ex'.
>
```

The repository includes `lib/common.ex` as checked-in generated output for the
MAVLink Common dialect. Treat generated dialect modules as build artifacts:
change the generator or XML input and regenerate them rather than editing or
formatting generated files by hand. The generator emits deterministic,
formatter-compatible source for repeatable diffs.

Treat MAVLink XML dialect files as trusted build inputs. The generator enforces
basic include graph, file size, identifier, reserved-name, and
duplicate-definition checks, but it is meant for upstream or application-owned
dialect files, not arbitrary untrusted XML.

## Public API Surface

The supported API is the documented HexDocs surface:

- Core runtime modules: `XMAVLink.Router`, `XMAVLink.Frame`,
  `XMAVLink.Message`, `XMAVLink.Signing`, and `XMAVLink.Heartbeat`.
- Utility modules under `XMAVLink.Util.*`, except modules hidden from HexDocs.
- Dialect and generator support: `XMAVLink.Dialect`, `XMAVLink.Parser`,
  `XMAVLink.Types`, `XMAVLink.Utils`, and `mix xmavlink`.
- Generated dialect modules, including the checked-in `Common` dialect.

Application, supervisor, connection worker, transport delegate, routing helper,
and inbound parser implementation modules are internal. They may appear in
types, logs, or stack traces, but downstream applications should use the
documented router, utility, generated dialect, and message APIs instead of
depending on those internals.

## Configuring the XMAVLink Application

Add the `:xmavlink` OTP application with no start arguments to your `mix.exs`.
You need to point the application at the dialect you just generated
and list the connections to other vehicles in `config.exs`:

```
config :xmavlink, dialect: Common, connections: ["serial:/dev/cu.usbserial-A603KH3Y:57600", "udpout:127.0.0.1:14550", "tcpout:127.0.0.1:5760"]
```

The above config specifies the Common dialect we generated and connects to a
vehicle on a radio modem, a UDP peer listening on port 14550, and a SITL vehicle
listening for TCP connections on port 5760. For configured network transports,
`out` means XMAVLink connects or sends to a remote endpoint. `udpin` means
XMAVLink opens a local UDP socket and receives packets from peers. TCP server
mode is not currently supported.

By default the application supervises one router registered as `XMAVLink.Router`.
Set `:router_name` when the application-owned router should use another registered
name:

```elixir
config :xmavlink,
  router_name: MyApp.MAVRouter,
  dialect: Common,
  connections: []
```

### Connection String Formats

XMAVLink supports the following connection string formats:

- **Serial**: `serial:<device_path>:<baud_rate>` (e.g., `"serial:/dev/ttyUSB0:57600"`)
- **UDP Out (client)**: `udpout:<address>:<port>` (e.g., `"udpout:192.168.1.100:14550"`)
- **UDP In (server)**: `udpin:<address>:<port>` (e.g., `"udpin:0.0.0.0:14550"`)
- **TCP Out (client)**: `tcpout:<address>:<port>` (e.g., `"tcpout:192.168.1.100:5760"`)

There is no `tcpin` connection string. TCP is currently supported only as an
outbound client connection, primarily for SITL endpoints.

### Configured Connection Lifecycle

Configured serial, UDP, and TCP connections run under a per-router dynamic
supervisor. Each connection has a worker process that owns its socket or UART
resource, forwards inbound frames to the router, and reconnects after open
failures or TCP/serial disconnects.

By default, connection workers retry every 1000 ms. Override the retry delay
with `:connection_retry_ms`:

```elixir
config :xmavlink,
  dialect: Common,
  connections: ["tcpout:127.0.0.1:5760"],
  connection_retry_ms: 500
```

### Remote Forwarding

By default, XMAVLink behaves as a router: frames received from one remote link
may be forwarded to other remote links as well as local subscribers. For
endpoint or GCS applications that should receive vehicle traffic without
bridging it between links, disable remote forwarding:

```elixir
config :xmavlink,
  dialect: Common,
  connections: ["udpin:0.0.0.0:14550"],
  remote_forwarding: false
```

With `remote_forwarding: false`, inbound remote frames are still decoded,
learned for routing, and delivered to local subscribers. Local messages sent
with `XMAVLink.Router.pack_and_send/2` or `/3` can still be forwarded to learned
remote vehicles.

### DNS Hostname Support

As of version 0.4.2, XMAVLink supports DNS hostnames in addition to IP addresses for network connections. This is particularly useful in:

- **Kubernetes/Docker environments** where services are accessed via DNS names
- **Cloud deployments** where static IPs may not be available
- **Development environments** using service discovery

Examples:

```elixir
config :xmavlink,
  dialect: APM.Dialect,
  connections: [
    # Using DNS hostname
    "udpout:router-service.namespace.svc.cluster.local:14550",
    # Using localhost
    "tcpout:localhost:5760",
    # Traditional IP address (still supported)
    "udpout:192.168.1.100:14551"
  ]
```

The router will automatically resolve DNS hostnames to IP addresses at startup. If a hostname cannot be resolved, the router will raise an `ArgumentError` with details about the resolution failure.

### Heartbeat emission

Most MAVLink nodes (cameras, GCSes, companion computers, autopilots) must emit a `HEARTBEAT` roughly once per second so peers know they're alive. Without it, dynamic / peer-learning routers (including the reference `mavlink-router`) won't forward traffic to them. xmavlink does not emit `HEARTBEAT` by default; opt in via the `:heartbeat` config:

```elixir
config :xmavlink,
  dialect: Common,
  connections: ["udpout:127.0.0.1:14550"],
  heartbeat: [
    interval_ms: 1000,
    message: %Common.Message.Heartbeat{
      type: :mav_type_gcs,
      autopilot: :mav_autopilot_invalid,
      base_mode: MapSet.new(),
      custom_mode: 0,
      system_status: :mav_state_active,
      mavlink_version: 3
    }
  ]
```

For nodes whose heartbeat reflects runtime state (`system_status`, `base_mode`, `custom_mode`), pass a `{module, function, args}` builder instead. The MFA is invoked on every tick to produce a fresh struct:

```elixir
config :xmavlink,
  heartbeat: [
    interval_ms: 1000,
    builder: {MyApp.Mavlink, :build_heartbeat, []}
  ]
```

The first heartbeat is sent immediately so peer-learning routers admit the node within milliseconds of startup. If `:heartbeat` is unset or `nil`, no heartbeats are emitted (backwards-compatible with versions ≤ 0.6.0; consumers that emit their own heartbeats are unaffected).

When multiple local MAVLink identities share one BEAM and one router, use
`:heartbeats` and set an explicit source identity per emitter:

```elixir
config :xmavlink,
  heartbeats: [
    [
      id: :camera_heartbeat,
      source_system: 1,
      source_component: 100,
      interval_ms: 1000,
      builder: {CameraApp.Mavlink, :heartbeat_message, []}
    ],
    [
      id: :gcs_heartbeat,
      source_system: 245,
      source_component: 191,
      interval_ms: 1000,
      builder: {GcsApp.Mavlink, :heartbeat_message, []}
    ]
  ]
```

## Receive MAVLink messages

With the configured MAVLink application running you can subscribe to particular MAVLink messages:

```
alias XMAVLink.Router, as: MAV

defmodule Echo do
  def run() do
    receive do
      msg ->
        IO.inspect msg
    end
    run()
  end
end

MAV.subscribe source_system: 1, message: APM.Message.Heartbeat
Echo.run()
```

or send a MAVLink message:

```
alias XMAVLink.Router, as: MAV
alias Common.Message.RcChannelsOverride

MAV.pack_and_send(
  %RcChannelsOverride{
    target_system: 1,
    target_component: 1,
    chan1_raw: 1500,
    chan2_raw: 1500,
    chan3_raw: 1500,
    chan4_raw: 1500,
    chan5_raw: 1500,
    chan6_raw: 1500,
    chan7_raw: 1500,
    chan8_raw: 1500,
    chan9_raw: 0,
    chan10_raw: 0,
    chan11_raw: 0,
    chan12_raw: 0,
    chan13_raw: 0,
    chan14_raw: 0,
    chan15_raw: 0,
    chan16_raw: 0,
    chan17_raw: 0,
    chan18_raw: 0
  }
)
```

Pass `source_system` and `source_component` when a process needs to emit a
message from an identity other than the router's configured default:

```elixir
MAV.pack_and_send(message, 2, source_system: 245, source_component: 191)
```

## Router Architecture

The XMAVLink application is to Elixir/Erlang code what [MAVProxy](https://ardupilot.org/mavproxy/)
is to its Python modules: a router that sits alongside them and gives them access to other MAVLink
systems over its connections. Unlike MAVProxy it is not responsible for starting/stopping/scheduling
Elixir/Erlang code.

### Router instance model

`XMAVLink.Router` remains the default convenience router name. Applications that
need multiple independent routers can supervise named router instances and pass
the router name or pid as the first argument to the public API:

```elixir
children = [
  {XMAVLink.Router,
   %{
     name: MyApp.VehicleRouter,
     dialect: Common,
     system: 245,
     component: 191,
     connections: ["udpout:127.0.0.1:14550"]
   }}
]

XMAVLink.Router.subscribe(MyApp.VehicleRouter, message: Common.Message.Heartbeat)
XMAVLink.Router.pack_and_send(MyApp.VehicleRouter, message)
XMAVLink.Router.unsubscribe(MyApp.VehicleRouter)
```

Named routers keep separate connection state, route tables, local sequence
numbers, and subscription restart caches. Passing no router target continues to
use the default `XMAVLink.Router` process.

The router is supervised. On a failure the configured connections and previous subscriptions are 
restored immediately. If a connection fails or is not available at startup the router will attempt to
reconnect each second and continue routing frames on the remaining connections. If a subscriber fails
it will be automatically unsubscribed and any new subscriber will be responsible for reconnection.

## Utilities

As of version 0.5.0, XMAVLink includes utility modules (previously in the separate xmavlink_util package) for performing common MAVLink commands and tasks with remote vehicles. These utilities provide:

- **Cache Manager**: Automatically caches received messages and parameters from visible MAV systems
- **Focus Manager**: Manage focus on specific vehicles for streamlined interactive sessions
- **Arm/Disarm**: Simple functions to arm and disarm vehicles
- **Parameter Management**: Request and set vehicle parameters
- **SITL Support**: Forward RC channels for Software-In-The-Loop simulation

The utility layer is opt-in because `CacheManager` subscribes to MAVLink traffic
and requests vehicle parameter lists when vehicles appear. Enable it for the
configured application router with:

```elixir
config :xmavlink,
  utilities: true
```

MAVLink transports are commonly deployed on trusted local links. If an
application exposes a UDP listener to a less trusted network, disable automatic
parameter-list requests and start them deliberately after deciding a vehicle is
trusted:

```elixir
config :xmavlink,
  utilities: [auto_param_request: false]
```

or supervise it explicitly when using a named router:

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
  {XMAVLink.Util.Supervisor, router: MyApp.VehicleRouter}
]
```

Pass `auto_param_request: false` to `XMAVLink.Util.Supervisor` for the same
behavior when supervising utilities explicitly.

As of `0.14.0`, utility helpers are scoped through
`XMAVLink.Util.Context`. A context identifies the router, generated dialect, and
ETS table namespace used by cache, focus, parameter, arm/disarm, and SITL
helpers:

```elixir
context =
  XMAVLink.Util.Context.new(
    router: MyApp.VehicleRouter,
    dialect: Common,
    table_prefix: :vehicle_a
  )

XMAVLink.Util.CacheManager.mavs(context: context)
XMAVLink.Util.CacheManager.msg({1, 1, 2}, Common.Message.Heartbeat, context: context)
XMAVLink.Util.ParamSet.param_set(1, 1, 2, "SYSID_THISMAV", 2.0, context: context)
```

The default context still uses the configured `:xmavlink` router and dialect,
with the historical table names `:messages`, `:systems`, `:params`, and
`:sessions`. Applications that read utility ETS tables directly should migrate
to `XMAVLink.Util.Context.new/1` and `XMAVLink.Util.Tables.name/2` instead of
hard-coding those names. See [MIGRATING_0_14.md](MIGRATING_0_14.md) for
examples and public cache query APIs that avoid direct ETS reads.

Command helpers such as arm/disarm and parameter setting use bounded retry
loops by default. Pass `:retries`, `:retry_interval_ms`, or `:context` in the
options when a helper needs different behavior. Parameter queries return maps
keyed by MAVLink parameter names as strings. `XMAVLink.Util.SITL.forward_rc/2`
also accepts `:destination_address` when the SITL RC input is not on loopback.

## Roadmap

- Signed MAVLink v2 messages

## Source

Copied from [https://github.com/beamuav/elixir-mavlink](https://github.com/beamuav/elixir-mavlink) on 2023-01-01.
