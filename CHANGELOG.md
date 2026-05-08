# Changelog

## Unreleased

## 0.12.0 - 2026-05-08

- Added MAVLink 2 signed-frame parsing and signature trailer representation.
- Added a low-level MAVLink 2 frame signing helper for already packed frames.
- Added reusable MAVLink 2 signature validation and inbound replay-policy
  helpers.
- Added inbound router and connection signing policy wiring so configured
  receive paths can verify signed MAVLink 2 frames, reject replayed signatures,
  and reject unsigned MAVLink 2 frames by default while signing is enabled.
- Added outbound router signing for unsigned MAVLink 2 frames sent over
  signing-enabled connections, with per-connection timestamp increments.
- Added MAVLink 2 signing timestamp load/save callbacks so applications can
  persist local signing timestamps across restarts.
- Made inbound `SETUP_SIGNING` frames local-only so key material is not
  forwarded between MAVLink links by generic routing.

## 0.11.1 - 2026-05-08

- Made generated MAVLink 2 packers use zero-equivalent defaults for omitted
  extension fields while preserving MAVLink 1 packing behavior.
- Added generator coverage for omitted and provided MAVLink 2 extension values,
  including scalar, array, enum, bitmask, float, double, and char fields.

## 0.11.0 - 2026-05-08

- Added the MAVLink 1.0 spec alignment checklist and support statement, with
  MAVLink 2 as the primary compatibility target.
- Made generated MAVLink 2 unpackers ignore future extension bytes for forward
  compatibility with dialects that append extension fields.
- Preserved MAVLink 2 zero-length payloads, consumed unsupported signed-frame
  signature trailers on stream transports, and aligned generated bitmask fields
  with XML `bitmask="true"` declarations.

## 0.10.2 - 2026-05-08

- Dropped unsupported MAVLink 2 frames with incompatible flags on UDP receive
  paths instead of crashing while attempting to validate a nil frame.
- Added `auto_param_request: false` utility configuration for deployments that
  need to discover vehicles before automatically requesting parameter lists.
- Documented security reporting, MAVLink trust boundaries, and trusted-input
  expectations for dialect XML generation.

## 0.10.1 - 2026-05-07

- Made generated dialect source deterministic and formatter-compatible by
  removing timestamp/path churn, combining parsed XML inputs in stable order,
  formatting the generated output before writing it, and including generated
  Common output in the formatter gate.

## 0.10.0 - 2026-05-07

- Made utility supervision opt-in and documented how to start utilities for
  the configured router or an explicitly supervised named router.
- Clarified that the current utility layer is scoped to one selected router per
  VM while the core router API remains the multi-router integration surface.
- Changed utility focus and cache helpers to return normal `{:error, reason}`
  results when utility state or MAV data is missing.
- Added bounded retry behavior and cleanup for arm/disarm, parameter request,
  and parameter set helpers.
- Changed parameter query results to use MAVLink parameter names as string keys
  instead of creating atoms from vehicle-provided input.
- Added configurable SITL RC forwarding destination addresses.

## 0.9.1 - 2026-05-07

- Strengthened CI release gates with formatting, warnings-as-errors, xref,
  tests, and Dialyzer coverage across the supported toolchain checks.
- Clarified supported transports and MAVLink 2 limitations in public docs.
- Fixed utility process lifecycle issues in `CacheManager` and `FocusManager`.

## 0.9.0 - 2026-05-07

- Moved configured connection startup and reconnect behavior under supervised
  per-router connection workers with explicit retry delays.
- Added documentation and coverage for connection worker retry/reconnect
  behavior.

## 0.8.0 - 2026-05-07

- Added named router instance support while preserving the default
  `XMAVLink.Router` convenience process.
- Added targetable `subscribe`, `unsubscribe`, and `pack_and_send` router APIs
  for named or pid router instances.
- Isolated local subscription restart caches per named router.

## 0.7.1 - 2026-05-07

- Fixed TCP outbound forwarding to send MAVLink frames over the TCP socket
  instead of attempting to use UDP send calls.
- Added TCP forwarding regression coverage for MAVLink 1 and MAVLink 2 frames.
- Reduced expected test-suite noise from generated task output and runtime logs.

## 0.7.0 - 2026-05-07

- Added per-message `source_system` and `source_component` overrides to
  `XMAVLink.Router.pack_and_send/3`.
- Added heartbeat source identity options and `:heartbeats` supervisor config
  for multiple local MAVLink identities sharing one router.
- Fixed outbound local sequence tracking so each local source identity uses an
  independent MAVLink sequence counter.
- Preserved the existing default router identity behavior for callers that do
  not pass source overrides.
