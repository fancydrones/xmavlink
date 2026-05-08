# MAVLink Spec Alignment for 1.0

Review date: 2026-05-08

Primary references:

- MAVLink packet serialization: https://mavlink.io/en/guide/serialization.html
- MAVLink routing: https://mavlink.io/en/guide/routing.html
- MAVLink 2 overview: https://mavlink.io/en/guide/mavlink_2.html
- MAVLink 2 signing: https://mavlink.io/en/guide/message_signing.html
- MAVLink XML schema guide: https://mavlink.io/en/guide/xml_schema.html

## 1.0 Support Posture

XMAVLink's 1.0 compatibility target is MAVLink 2 first. MAVLink 1 remains
supported for basic frame parsing, packing, and routing while that support stays
cheap to maintain, but MAVLink 1-only work should not displace MAVLink 2
correctness. If a future gap requires significant MAVLink 1-specific
investment, prefer an explicit support reduction over slowing MAVLink 2 work.

Supported runtime scope:

- MAVLink 2 unsigned frames without incompatible flags.
- MAVLink 2 signed-frame boundary parsing and signature trailer
  representation. Configured inbound signed frames are authenticated before
  unpacking and routed with replay protection.
- MAVLink 1 frames for existing users and legacy links.
- Serial, `udpin`, `udpout`, and outbound TCP (`tcpout`) transports.
- Generated dialect modules from trusted MAVLink XML build inputs.

Known non-goals for 1.0 unless separately implemented:

- Outbound MAVLink 2 packet signing and timestamp persistence.
- TCP server (`tcpin`) transport.
- Treating untrusted XML dialect files as safe input.
- Full `mavgen` feature parity for XML validation, WIP filtering, and every
  generated helper surface.

## Checklist

| Area | Status | Notes |
| --- | --- | --- |
| MAVLink 2 frame shape | Supported | Parses and emits the v2 header, 24-bit message id, payload, checksum, and compatible flags. Unsupported incompatible flags are discarded. |
| MAVLink 2 signing | Partial | Signed-frame boundaries and the 13-byte signature trailer are parsed and represented. Configured inbound signed frames are verified before unpacking and routed with per-connection replay checks. Unsigned MAVLink 2 inbound frames are rejected by default while signing is enabled unless explicitly accepted. Outbound signing and timestamp persistence remain follow-up work. See #47 and `MAVLINK2_SIGNING.md`. |
| MAVLink 2 payload truncation | Supported | Outbound payloads trim trailing zero bytes while preserving a non-empty all-zero payload's first byte; inbound v2 payloads are padded back to known dialect length before unpacking. |
| MAVLink 2 future extension bytes | Supported | Generated v2 unpack clauses now ignore trailing extension bytes that are unknown to the local dialect. This preserves extension-field forward compatibility. |
| MAVLink 2 extension CRC behavior | Supported | `CRC_EXTRA` generation excludes extension fields, matching the serialization guide. |
| MAVLink 2 extension field packing defaults | Supported | Omitted known extension fields are packed as zero-equivalent values for v2 messages while remaining omitted from v1 payloads. |
| MAVLink 1 frame shape | Supported | Existing parser/packer handles v1 framing, checksum, and 8-bit message ids. New MAVLink 1-only expansion is not a priority for 1.0. |
| CRC_EXTRA calculation | Supported | Field ordering is size-stable for base fields, arrays are ordered by element size, and extension fields are excluded. |
| Field ordering | Supported | Base fields are stably sorted by native type size; extension fields remain in XML declaration order. |
| Unknown message handling | Partial | Unknown known-shape frames are forwarded as broadcast when the message id is not present in the dialect. Unknown messages cannot expose target fields because the payload cannot be decoded. |
| Compatible flags | Supported | MAVLink 2 compatible flags are retained and otherwise ignored. |
| Incompatible flags | Partial | Unknown incompatible flags are discarded as required. Signing's known 13-byte trailer is consumed, but full signing support is tracked separately. |
| Routing unchanged packets | Supported for decoded/unknown unsigned frames and configured signed inbound frames | Forwarding uses the original raw frame bytes. Outbound generation of signed frames is not wired yet. |
| Target inference | Supported | Generated metadata classifies broadcast, system, component, and system-component targets from `target_system` and `target_component` fields. |
| Route reset after reboot | Partial | Routing learns source system/component locations but does not yet clear routes on `SYSTEM_TIME.time_boot_ms` decrease. |
| XML includes | Partial | Includes are recursive and deterministic, but missing include errors and duplicate handling are not yet aligned with `mavgen`. |
| Enum merging | Partial | Matching enum names are merged and sorted by value. Duplicate enum entries are not rejected yet. |
| Duplicate message ids | Unsupported validation | The parser/generator does not currently reject duplicate message ids across includes. |
| XML `bitmask="true"` | Supported | Enum-level bitmask declarations are parsed and used before heuristic bitmask detection. |
| XML identifiers and source generation safety | Partial | XML is treated as trusted build input. Identifier validation and safer escaping are tracked separately in #49. |
| Generated Common dialect | Supported within above scope | `lib/common.ex` is regenerated from `config/common.xml` and should be treated as build output. |

## Changes Made In This Pass

- Generated MAVLink 2 unpackers now accept extra trailing bytes after all
  locally known fields and ignore them as future extension fields.
- Generated unpack specs now match the actual `unpack/3` runtime API and include
  an `unpack/3` fallback.
- Generated modules now compile for XML dialects with no enums or units.
- Enum-level `bitmask="true"` is parsed and reflected in generated field types,
  packing, and unpacking.
- Generated MAVLink 2 packers use zero-equivalent defaults for omitted known
  extension fields.
- MAVLink 2 signed frames now parse the 13-byte signature trailer into frame
  metadata.
- Low-level MAVLink 2 frame signing can set the signed incompatibility flag,
  recalculate checksum bytes, and append a generated signature trailer for an
  already packed frame.
- Low-level MAVLink 2 signing validation can verify signed frames and reject
  replayed or too-old timestamps.
- Inbound router and connection signing policy can verify signed MAVLink 2
  frames before unpacking, track replay state per connection, and reject
  unsigned MAVLink 2 frames by default while signing is enabled.
- Unsupported signed MAVLink 2 frames consume the 13-byte signature trailer when
  present, preventing TCP/serial stream buffers from treating signature bytes as
  a new frame prefix.
- MAVLink 2 packing now preserves a truly empty payload as length zero.
- Core MAVLink integer types were tightened for the signed 32-bit minimum and
  unsigned 64-bit zero value.

## Follow-Up Issues

- #47: Continue MAVLink 2 packet signing with outbound signing, timestamp
  persistence hooks, and `SETUP_SIGNING` handling.
- #52: Add route invalidation when `SYSTEM_TIME.time_boot_ms` decreases for a
  known system/component.
- #53: Align XML parser/generator validation with `mavgen` for missing
  includes, duplicate message ids, duplicate enum entries, and reserved names.

These follow-ups should be prioritized by MAVLink 2 impact first. None of the
reviewed gaps require new MAVLink 1-only work before 1.0.
