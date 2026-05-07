# Repository Guidelines

## Project Overview

XMAVLink is an Elixir/Mix library and OTP application for MAVLink communication over serial, UDP, and TCP connections. Core runtime code lives under `lib/mavlink`, utility modules under `lib/mavlink_util`, the dialect generator Mix task in `lib/mix/tasks/mavlink_task.ex`, and tests in `test`.

`lib/common.ex` is a checked-in generated MAVLink dialect module. Treat it as generated output: prefer changing the generator or XML inputs, then regenerating, instead of hand-editing it. Regeneration can create large diffs because generated module docs include timestamps.

## Environment

- Use the versions in `.tool-versions`: Elixir 1.18.4 and Erlang/OTP 27.3.4.3.
- Install dependencies with `mix deps.get`.
- The Mix `test` alias runs `mix test --no-start`; tests should not assume the application supervision tree starts automatically.

## Common Commands

- `mix deps.get` - fetch dependencies.
- `mix format` - format source according to `.formatter.exs`.
- `mix test` - run the full test suite with the app not started.
- `mix test test/path_to_test.exs` - run a focused test file.
- `mix xmavlink path/to/dialect.xml output/path.ex ModuleName` - generate an Elixir dialect module from MAVLink XML.
- `mix dialyzer` - run Dialyzer when type/spec changes warrant it and PLTs are available.

## Code Style

- Follow idiomatic Elixir and existing module patterns.
- Keep public API specs and docs accurate when behavior changes.
- Prefer pattern matching and small helper functions over broad conditional logic.
- Keep comments short and useful; avoid narrating obvious code.
- Do not introduce application startup in tests unless a test explicitly needs supervision behavior.

## Testing Notes

- Router, heartbeat, parser, utility, and generator behavior are covered in focused ExUnit files under `test`.
- Generator tests write to `test/output`, which is ignored by git.
- Network and serial connection code can touch local ports or device resources. Prefer unit-level tests with controlled state unless the task explicitly involves integration behavior.
- `config/config.exs` contains example MAVLink connection settings; avoid relying on those defaults in tests unless intentionally exercising configuration.

## Git Hygiene

- The worktree may contain user changes. Do not revert unrelated edits.
- Keep changes scoped to the requested behavior and add tests for behavioral changes.
- Before handing off code changes, run at least `mix format` and the relevant `mix test` target; run the full suite when the blast radius is broader.
