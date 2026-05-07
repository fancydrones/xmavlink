# QA checks

The release gate in CI runs these checks across the supported Elixir/OTP matrix:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix xref graph --label compile-connected --fail-above 0
mix test --warnings-as-errors
```

`mix dialyzer` is not part of the required CI gate yet because the current code
base still has a known warning tracked by v1.0.0 readiness issue #31. Add it to
CI once that warning is resolved or formally excluded.

# Testing locally with ArduPilot, MAVProxy, SITL, and X-Plane

Use the upstream ArduPilot documentation as the source of truth for installing
and running SITL and MAVProxy:

- https://ardupilot.org/dev/docs/SITL-setup-landingpage.html
- https://ardupilot.org/dev/docs/using-sitl-for-ardupilot-testing.html
- https://ardupilot.org/mavproxy/docs/getting_started/download_and_installation.html

The old local instructions used Python 2 and global `sudo pip` installs. Do not
use those for new setup. Current ArduPilot tooling is Python 3 based; prefer the
platform-specific upstream setup, a virtual environment, or user-local install.

For a local XMAVLink smoke test, start SITL through `sim_vehicle.py` and add or
verify a MAVProxy UDP output to the port XMAVLink will use. On a typical local
SITL session, MAVProxy already exposes UDP outputs on `127.0.0.1:14550` and
`127.0.0.1:14551`; confirm with:

```
output
```

If needed, add an output explicitly from the MAVProxy prompt:

```
output add 127.0.0.1:14550
```

Then configure XMAVLink with a matching UDP listener:

```elixir
config :xmavlink,
  dialect: Common,
  connections: ["udpin:0.0.0.0:14550"]
```

or run a script that starts a router with the same connection string.

For TCP-based SITL, connect XMAVLink as a TCP client:

```elixir
config :xmavlink,
  dialect: Common,
  connections: ["tcpout:127.0.0.1:5760"]
```

XMAVLink does not currently provide a TCP server (`tcpin`) transport.

## X-Plane

It's possible to use SITL with X-Plane:

https://ardupilot.org/dev/docs/sitl-with-xplane.html

Start X-Plane and set up the data export settings per the upstream page, then
run ArduPlane and MAVProxy. A MAVProxy output can forward frames to an XMAVLink
UDP listener:

```
mavproxy.py --master=tcp:127.0.0.1:5760 --out 127.0.0.1:14550
```

Then run an XMAVLink script or application configured with:

```elixir
connections: ["udpin:0.0.0.0:14550"]
```

For example:

```bash
mix run scripts/listen.exs
```

will receive messages if the script starts a matching listener.

## MAVProxy noise setting

```
set shownoise False
```

Which can also be added to `~/.mavinit.scr` to run every time `mavproxy.py` runs.

# Testing against real message definition files

In another directory (like `..`):

```bash
git clone git@github.com:mavlink/mavlink.git
cd mavlink
```

The message definitions live in:

```
message_definitions/v1.0
```

To generate a protocol file for APM:

```bash
mkdir message_definitions
cp ../mavlink/message_definitions/v1.0/* message_definitions
mix xmavlink message_definitions/ardupilotmega.xml output/apm.ex APM
```

## Example usage

```elixir
defmodule TestLog do
  def start do
    XMAVLink.Router.subscribe(message: Common.Message.VfrHud)
    # XMAVLink.Router.subscribe(message: Common.Message.SysStatus)
    # XMAVLink.Router.subscribe(message: Common.Message.Heartbeat)
    # XMAVLink.Router.subscribe(message: Common.Message.GlobalPositionInt)
    loop()
  end

  def loop do
    receive do
      x ->
        IO.inspect(x)
        loop()
    end
  end
end

TestLog.start()
```
