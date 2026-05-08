# MAVLink 2 Signing Plan

Primary references:

- MAVLink message signing: https://mavlink.io/en/guide/message_signing.html
- MAVLink packet serialization: https://mavlink.io/en/guide/serialization.html

## Current State

XMAVLink parses the MAVLink 2 signing incompatibility flag (`0x01`) as a known
frame-shape feature and extracts the 13-byte signing trailer into
`XMAVLink.Frame.Signature`.

`XMAVLink.Frame.sign_frame/4` can sign an already packed MAVLink 2 frame when
given a 32-byte key, link id, and timestamp. This is a low-level utility for the
remaining signing implementation; router and connection configuration do not
use it yet.

`XMAVLink.Frame.validate_signature/2` verifies the 48-bit signature for a
parsed signed frame. `XMAVLink.Signing.validate_inbound/2` adds the policy
state needed for replay protection by tracking the last accepted timestamp per
`{source_system, source_component, link_id}` stream and rejecting first-seen
streams more than 6,000,000 ticks behind the local signing timestamp.

Frames received by the router are still not authenticated, unpacked, delivered
to subscribers, or forwarded when they are signed. Until router and connection
policy wiring exists, `XMAVLink.Frame.validate_and_unpack/2` returns
`:signed_frame_unsupported` for parsed signed frames.

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

Signing should be configured per router or per connection. The likely public
shape is:

- `signing: nil` or omitted: current unsigned behavior, but signed frames remain
  rejected until an explicit acceptance policy is configured.
- `signing: [secret_key: <<_::256>>, link_id: 0..255, timestamp_source: ...]`:
  validate inbound signed frames and sign outbound MAVLink 2 frames on that
  connection.
- `accept_unsigned: false | true`: explicit policy for unsigned frames when
  signing is enabled. The policy helper defaults to reject.
- `accept_invalid_signatures: false`: default. Any diagnostic override must be
  explicit and visible to callers.

## Required Follow-Up Work

1. Router and connection policy:
   - decide where per-link timestamp state lives;
   - make unsigned-frame acceptance explicit;
   - avoid forwarding `SETUP_SIGNING` from a secure link to other links.
2. Signed unpack/routing:
   - call `XMAVLink.Signing.validate_inbound/2` before unpacking signed frames;
   - allow validated signed frames through checksum validation and dialect
     unpacking;
   - keep invalid signed frames invisible to subscribers and route tables.
3. Outbound signing policy:
   - call the low-level frame signing utility from router/connection send paths;
   - monotonically increment timestamps per outbound link;
   - keep MAVLink 1 behavior unsigned and unchanged.
4. Persistence hooks:
   - expose timestamp load/save integration points;
   - document that applications must store keys and timestamps securely.

Each step should land with focused tests before #47 is closed.
