# Changelog

## 0.7.0 - 2026-05-07

- Added per-message `source_system` and `source_component` overrides to
  `XMAVLink.Router.pack_and_send/3`.
- Added heartbeat source identity options and `:heartbeats` supervisor config
  for multiple local MAVLink identities sharing one router.
- Fixed outbound local sequence tracking so each local source identity uses an
  independent MAVLink sequence counter.
- Preserved the existing default router identity behavior for callers that do
  not pass source overrides.
