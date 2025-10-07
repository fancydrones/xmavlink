# XMAVLink

This library includes a mix task that generates code from a MAVLink xml
definition files and an application that enables communication with other
systems using the MAVLink 1.0 or 2.0 protocol over serial, UDP and TCP
connections.

MAVLink is a Micro Air Vehicle communication protocol used by Pixhawk, 
Ardupilot and other leading autopilot platforms. For more information
on MAVLink see https://mavlink.io.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `xmavlink` to your list of dependencies in `mix.exs`:

  ```elixir
 def deps do
   [
     {:xmavlink, "~> 0.5.0"}
   ]
 end
 ```

## Current Status

This library is not officially recognised or supported by MAVLink at this
time.

## Generating MAVLink Dialect Modules

MAVLink message definition files for popular dialects can be found [here](https://github.com/mavlink/mavlink/tree/master/message_definitions/v1.0).
To generate an Elixir source file containing the modules we need to speak a MAVLink dialect (for example ardupilotmega):

```
> mix xmavlink test/input/ardupilotmega.xml lib/apm.ex APM
* creating lib/apm.ex
Generated APM in 'lib/apm.ex'.
>
```

## Configuring the XMAVLink Application

Add `XMAVLink.Application` with no start arguments to your `mix.exs`. You need to point the application at the dialect you just generated 
and list the connections to other vehicles in `config.exs`:

```
config :xmavlink, dialect: Common, connections: ["serial:/dev/cu.usbserial-A603KH3Y:57600", "udpout:127.0.0.1:14550", "tcpout:127.0.0.1:5760"]
```

The above config specifies the Common dialect we generated and connects to a a vehicle on a radio modem, a ground station listening for 
UDP packets on 14550 and a SITL vehicle listening for TCP connections on 5760. Remember 'out' means client, 
'in' means server.

### Connection String Formats

XMAVLink supports the following connection string formats:

- **Serial**: `serial:<device_path>:<baud_rate>` (e.g., `"serial:/dev/ttyUSB0:57600"`)
- **UDP Out (client)**: `udpout:<address>:<port>` (e.g., `"udpout:192.168.1.100:14550"`)
- **UDP In (server)**: `udpin:<address>:<port>` (e.g., `"udpin:0.0.0.0:14550"`)
- **TCP Out (client)**: `tcpout:<address>:<port>` (e.g., `"tcpout:192.168.1.100:5760"`)
- **TCP In (server)**: `tcpin:<address>:<port>` (e.g., `"tcpin:0.0.0.0:5760"`)

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

## Router Architecture

The XMAVLink application is to Elixir/Erlang code what [MAVProxy](https://ardupilot.org/mavproxy/)
is to its Python modules: a router that sits alongside them and gives them access to other MAVLink
systems over its connections. Unlike MAVProxy it is not responsible for starting/stopping/scheduling
Elixir/Erlang code.

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

See the included `.iex.exs` file for convenient helper imports to use in IEx sessions, providing an interactive experience similar to MAVProxy.

## Roadmap

- Signed MAVLink v2 messages

## Source

Copied from [https://github.com/beamuav/elixir-mavlink](https://github.com/beamuav/elixir-mavlink) on 2023-01-01.
