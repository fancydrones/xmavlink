# Changelog

## Unreleased

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
