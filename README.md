# TurtleGPS

A live GPS map and command system for a CC:Tweaked turtle fleet that spans the
Overworld, the Nether and the End. You use it from a big advanced monitor in a control room
and from an advanced pocket computer anywhere.

Pure CC:Tweaked Lua, no external libraries. Advanced Peripherals is used for the Chunky
Turtle upgrade, Player Detector and Chat Box.

## Status

| Milestone | What | State |
|---|---|---|
| 1 | Heartbeats + turtle dots on the control room monitor | **ready for in-game test** |
| 2 | Pocket app + Player Detector players on the map | next |
| 3 | goto / return / come-to-me commands with movement safety | |
| 4 | Terrain fill-in | |
| 5 | Jobs (mine area, chop trees, farm) in every dimension | |

Milestone 1 also ships the parts every later milestone relies on:

- signed messaging with replay protection and an allowlist
- the dimension-aware GPS host and its self-check
- over-the-air updates with automatic rollback
- a single-file installer
- the mock test harness

## How it fits together

```
 Overworld                      Nether                        End
 ┌───────────────┐              ┌───────────────┐             ┌───────────────┐
 │ 4 GPS hosts   │              │ 4 GPS hosts   │             │ 4 GPS hosts   │
 │ turtles ──┐   │              │ turtles ──┐   │             │ turtles ──┐   │
 └───────────┼───┘              └───────────┼───┘             └───────────┼───┘
             │   ender modems: signed rednet, every message has a dim     │
             └──────────────────────┬───────┴──────────────────────────────┘
                          ┌─────────▼──────────┐         ┌──────────────────┐
                          │ CONTROL computer   │◄───────►│ pocket computers │
                          │ dispatcher + map   │         │ (milestone 2)    │
                          │ server + monitor   │         └──────────────────┘
                          └────────────────────┘
```

- **Turtles** can't use portals, so each dimension has its own fleet, garage and four-host
  GPS constellation. A turtle tracks its position by dead reckoning on every move and
  corrects it with GPS fixes. It sends a heartbeat every 3 s with: id, label, x/y/z,
  heading, dimension, fuel, inventory fullness, job and status.
- **GPS hosts** answer pings with `{x, y, z, dim = ...}`, so a turtle or pocket learns which
  dimension it is in. Stock `gps.locate` still works with them. Each host checks the others'
  coordinates and flags a mistyped one on its screen.
- **The control computer** stores turtles, GPS hosts and alerts in `/fleet/data` and draws
  the map. When a turtle goes silent it is marked stale and then LOST, which raises an alert
  on the monitor and sends a Chat Box message to you. Low fuel and full inventories also
  raise alerts.
- **Security:** every message is signed with HMAC-SHA256 using the shared secret, and
  stamped with a time and a nonce. The secret never goes over the air. Messages that are
  forged, replayed, expired or from the wrong sender are dropped. Commands are also checked
  against an allowlist of computer IDs, and turtles only obey the control computer.
- **Updates:** reinstall only the control computer. Every other fleet computer sees the new
  code version in its heartbeat reply, downloads the changed files and checks each one's
  hash. It keeps a backup and reboots. If the new code crashes 3 times, it rolls back on
  its own.

## Getting started

1. Read [docs/SETUP.md](docs/SETUP.md): hardware, GPS host placement, installing.
2. Do the Milestone 1 checks in [docs/TESTING.md](docs/TESTING.md#milestone-1-in-game-checklist)
   and report back what you see.

## Developing

```
sudo apt install lua5.2          # same Lua version as CC:Tweaked's Cobalt VM
lua5.2 test/run.lua              # whole suite in the mock CC:Tweaked world (~1 min)
lua5.2 test/run.lua m1           # only tests whose name contains "m1"
sh tools/fetch_rom.sh && CC_ROM=test/rom/lua lua5.2 test/run.lua   # same suite on the real CraftOS ROM
lua5.2 tools/build.lua           # rebuild dist/install.lua after changing src/
python3 tools/render_screen.py test/out/m1_monitor.json   # look at a mock monitor
luacheck src tools test          # static checks (.luacheckrc)
```

53 tests cover: libraries, GPS, turtle navigation, milestone 1 end to end, OTA updates,
security, UI layouts, installer and setup, and failure modes (full disk, bad config, spam,
30-turtle load). They pass both with the built-in CraftOS ports and on the real CraftOS ROM.
[docs/VERIFIED.md](docs/VERIFIED.md) lists the CC:Tweaked and Advanced Peripherals behaviour
checked against their source.

Layout:

```
src/fleet/            installed to /fleet on every computer
  boot.lua            launcher: runs the role app, restarts on crash, rolls back bad updates
  app/                control.lua, turtle.lua, gpshost.lua, pocket.lua (one per role)
  lib/                sha2, ser, net (signed messages), locate (GPS), update (OTA), config, ...
  server/             fleet.lua (state, alerts), notify.lua (Chat Box / speaker)
  turtle/             nav.lua (dead reckoning + GPS + heading)
  ui/                 app.lua (the shared map UI), map.lua, fb.lua, glyphs.lua
  bin/                setup.lua, gpscheck.lua
dist/install.lua      single-file installer (generated)
test/                 mock harness (test/mock) and tests
tools/                build.lua, render_screen.py, fetch_rom.sh
docs/                 SETUP.md, TESTING.md, PROTOCOL.md, VERIFIED.md
```
