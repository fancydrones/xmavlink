# Security Policy

## Supported Versions

Security fixes are applied to the current supported release line. Before
`1.0.0`, use the latest published version or the default branch when evaluating
security-related fixes.

## Reporting a Vulnerability

Report vulnerabilities privately to the maintainer before opening public issues
with exploit details. Include the affected version or commit, a concise
reproduction, and the transport or generator input involved.

## Security Model

XMAVLink is a MAVLink transport and code generation library. MAVLink networks
are often local radio, serial, simulator, or vehicle LAN links, and unauthenticated
peers can send valid MAVLink frames unless the deployment adds its own access
control.

Current trust boundaries:

- MAVLink 1 and unsigned MAVLink 2 frames are parsed and routed when signing is
  not configured.
- Router-level MAVLink 2 signing can be configured for connections. Signed
  frames are verified before unpacking, replay timestamps are tracked per
  connection, and unsigned MAVLink 2 inbound frames are rejected by default
  while signing is enabled unless `accept_unsigned: true` is set. MAVLink 1
  inbound frames remain accepted under a signing policy. Unsigned outbound
  MAVLink 2 frames sent over signing-enabled connections are signed with a
  monotonically incremented per-connection timestamp. Timestamp persistence
  hooks are not wired yet. Frames with other incompatible MAVLink 2 flags are
  discarded.
- UDP listeners should be exposed only to trusted networks unless the application
  adds network-level filtering or validates peers at a higher layer.
- Utility processes are opt-in. When enabled, `CacheManager` subscribes to
  traffic and, by default, requests parameter lists from newly seen vehicles.
  Use `utilities: [auto_param_request: false]` or pass
  `auto_param_request: false` to `XMAVLink.Util.Supervisor` when vehicle
  discovery happens on a less trusted network.
- `mix xmavlink` treats MAVLink XML dialect files as trusted build inputs. Do
  not run the generator on arbitrary untrusted XML.
