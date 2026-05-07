# Changelog

## Unreleased

- Made generated dialect source deterministic and formatter-compatible by
  removing timestamp/path churn, combining parsed XML inputs in stable order,
  and formatting the generated output before writing it.

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
