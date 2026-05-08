# MAVLink 2 Signing Plan

Primary references:

- MAVLink message signing: https://mavlink.io/en/guide/message_signing.html
- MAVLink packet serialization: https://mavlink.io/en/guide/serialization.html

## Current State

XMAVLink parses the MAVLink 2 signing incompatibility flag (`0x01`) as a known
frame-shape feature and extracts the 13-byte signing trailer into
`XMAVLink.Frame.Signature`.

`XMAVLink.Frame.sign_frame/4` can sign an already packed MAVLink 2 frame when
given a 32-byte key, link id, and timestamp. Router forwarding uses it through
`XMAVLink.Signing.sign_outbound/2` when a signing-enabled connection sends an
unsigned MAVLink 2 frame.

`XMAVLink.Frame.validate_signature/2` verifies the 48-bit signature for a
parsed signed frame. `XMAVLink.Signing.validate_inbound/2` adds the policy
state needed for replay protection by tracking the last accepted timestamp per
`{source_system, source_component, link_id}` stream and rejecting first-seen
streams more than 6,000,000 ticks behind the local signing timestamp.

Routers accept a `:signing` configuration with `:secret_key`, `:link_id`,
`:timestamp`, and optional `:accept_unsigned`. Receive paths seed each
connection with that policy. Configured signed MAVLink 2 frames are verified
before dialect unpacking, delivered to subscribers, forwarded through the normal
routing logic, and recorded for replay protection. Unsigned MAVLink 2 inbound
frames are rejected by default while signing is enabled unless
`accept_unsigned: true` is set. MAVLink 1 frames remain accepted under a signing
policy. When signing is not configured, signed MAVLink 2 frames still return
`:signed_frame_unsupported`.

Outbound routing signs unsigned MAVLink 2 frames on signing-enabled
connections, updates that connection's local timestamp after each signed send,
and leaves MAVLink 1 frames unsigned. Already signed MAVLink 2 frames are
forwarded with their existing signature rather than being re-signed.

Unknown incompatible flags are still rejected. If a frame has both the signing
flag and unsupported incompatible flags, XMAVLink consumes the known 13-byte
signature trailer when present so stream transports keep frame boundaries, but
the packet is not accepted.

## Signature Frame Shape

The MAVLink 2 signed trailer is 13 bytes:

- `link_id`: 8-bit link identifier.
- `timestamp`: little-endian 48-bit timestamp in 10 microsecond units since
  2015-01-01 00:00:00 GMT.
- `signature`: 48-bit signature value.

The signature is defined as the first 48 bits of SHA-256 over the 32-byte shared
secret key followed by the wire header including the magic byte, payload, CRC,
link id, and timestamp.

## Intended Public Policy Shape

Signing is currently configured per router and copied into each connection:

- `signing: nil` or omitted: current unsigned behavior, but signed frames remain
  rejected until an explicit acceptance policy is configured.
- `signing: [secret_key: <<_::256>>, link_id: 0..255, timestamp: non_neg_integer]`:
  validate inbound signed MAVLink 2 frames, track inbound replay timestamps, and
  sign unsigned outbound MAVLink 2 frames on each connection.
- `accept_unsigned: false | true`: explicit policy for unsigned frames when
  signing is enabled. The policy helper defaults to reject.

## Required Follow-Up Work

1. Persistence hooks:
   - expose timestamp load/save integration points;
   - document that applications must store keys and timestamps securely.
2. `SETUP_SIGNING` handling:
   - avoid forwarding `SETUP_SIGNING` from a secure link to other links;
   - document any explicit provisioning workflow XMAVLink supports.

Each step should land with focused tests before #47 is closed.
