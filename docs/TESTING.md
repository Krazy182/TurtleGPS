# Testing

## Mock harness (outside Minecraft)

`test/mock` simulates several CC:Tweaked computers sharing a world, in simulated time, under
Lua 5.2 (the same language version as CC's Cobalt VM).

```
lua5.2 test/run.lua            # everything (light mode: built-in ports of CraftOS)
lua5.2 test/run.lua security   # tests whose name contains "security"
python3 tools/render_screen.py test/out/m1_monitor.json   # PNG of a mock monitor
```

### Real CraftOS mode

The harness can also boot the **actual CraftOS ROM** from CC:Tweaked: `bios.lua`, the shell,
multishell, `require`, the rednet daemon, `parallel`, `window` and `read()`. The mock then only
supplies what CC:Tweaked's Java side would (term, fs, os timers/events, peripherals, turtle).

```
sh tools/fetch_rom.sh                         # pinned CC:Tweaked 1.120.2 into test/rom (git-ignored)
CC_ROM=test/rom/lua lua5.2 test/run.lua       # whole suite on real CraftOS
python3 tools/render_screen.py test/out/m1_monitor.json --font test/rom/term_font.png  # pixel-exact
```

Both modes pass all tests. [VERIFIED.md](VERIFIED.md) lists what was checked against the
CC:Tweaked and Advanced Peripherals source.

It mimics the parts of CC that usually break programs in-game:

- **Events:** `os.pullEventRaw(filter)` is `coroutine.yield(filter)`, and events that don't
  match the filter are **dropped**, as in CC. `sleep` and the turtle API are ports of the
  CraftOS code, so they discard other events while waiting, and `parallel` is a port too.
- **Ender modems:** unlimited range in a dimension; across dimensions they deliver without a
  distance. Rednet uses the real CraftOS wire format, so an attacker test can sniff and
  replay raw modem traffic.
- **GPS:** real trilateration from modem distances, with the actual `gpshost` program
  answering.
- **Turtles:** fuel, blocked moves, world height limits, fluids, unbreakable blocks,
  inventory, equipping upgrades (unequipping the modem closes rednet), and turtle-to-turtle
  blocking.
- **Advanced Peripherals:** Player Detector and Chat Box, with their real return values and
  one-tick main-thread yields; speaker.
- **Monitors:** CC:Tweaked's monitor size formula and `monitor_touch`.
- **Limits:** the 256-event queue, 1 MB disk per computer ("Out of space").
- **Chunks:** `sim:unload(c)` / `sim:load(c)` stop a computer and turn it back on, which
  runs startup again.
- **"Too long without yielding":** instructions are counted per resume, which also flags
  expensive code. With 30 turtles and 12 GPS hosts, the control computer averages about
  1.3M Lua instructions per second and drops no events.

What it does not simulate: real tick timing or lag, chunk loading by the Chunky upgrade,
exact block-drop rules, and text rendering details. Those need your in-game results.

## Milestone 1 in-game checklist

Set up the control computer, one GPS constellation per dimension you use, and at least one
turtle per dimension (see [SETUP.md](SETUP.md)). Run `/fleet/bin/doctor` on each computer
once; anything it flags is worth fixing first. Then check:

**GPS**

1. Each GPS host screen: `Check: OK: 4 hosts, good 3D spread`, and `Served:` counts up as
   turtles locate.
2. `/fleet/bin/gpscheck` on a turtle or computer in each dimension prints
   `Position: x, y, z (Nether)` with the right coordinates and dimension.

**Turtles**

3. On boot the turtle moves one block and back, then its screen shows the right `Pos`,
   `Facing`, `Fix gps ...` and `Server OK (#<control id>)`.
4. Reboot the turtle (Ctrl+R) without moving it. It should **not** move this time, because
   it keeps its saved heading.

**Control monitor**

5. The top bar shows the dimension name with turtle count. Use ◄ ► to switch dimensions. Each
   turtle is a triangle pointing the way it faces, labelled with its name, at the right spot
   relative to the garage icon.
6. The `-` / `+` zoom and the arrow buttons pan. Tap a turtle: the side panel shows position,
   fix, fuel (with a bar), inventory, status and when it was last seen.
7. Tap an empty spot: a magenta `x` marks it and the side panel shows its x / z.
8. The side panel shows `GPS: 4 hosts OK` for the dimension you're viewing. Tap that line:
   it lists each host with its self-check result. Stop one host (Ctrl+T): after about 90 s it
   shows OFFLINE, and you get an alert and a Forget button.
9. The text scale is picked for you: 1 if the monitor still gets 60x24 characters, else 0.5.
   The control computer's log says which it chose. Tapping right next to a turtle selects it.
10. Reboot the control computer: the map comes back on the same dimension and zoom.

**Alerts**

11. Hold Ctrl+T on a turtle to stop its program. After ~12 s it turns grey ("STALE"). After
   ~45 s you get LOST: a red alert on the monitor, a chime from the speaker, and a private
   chat message from the Chat Box. Reboot the turtle and you get "OK: ... back online".
12. Hold Ctrl+R on the control computer to reboot it. After it comes back, there should be no
    false LOST alerts.
13. A turtle with less than 500 fuel raises a low-fuel alert. Tap the alert to acknowledge it
    and jump to that turtle.

**Security (optional)**

14. From a computer that is not set up with the secret, run
    `rednet.open("back") rednet.send(<control id>, "hi", "turtlegps")`. The control console
    should count it as rejected, and nothing else happens.

### What to send back

For anything that doesn't match:

- what you did, and what the screen showed (a screenshot is best)
- the text on the control computer's own screen (rejected / denied lines and the log)
- **a report link**: on the affected computer, stop TurtleGPS (Ctrl+T) and run
  `/fleet/bin/report`. It uploads one paste with the doctor results, logs, crash log,
  config (secret removed), peripherals and versions, then prints the link. The paste is
  *unlisted* and expires after a week. Please don't use `pastebin put` for logs: CC uploads
  those as **public** pastes, and logs contain your coordinates.
- versions: Minecraft, CC:Tweaked, Advanced Peripherals
- your monitor size in blocks, and the text scale the log says it picked
- the Advanced Peripherals config values `playerSpy` and `chatBoxMultiDimensional`, if
  alerts or players don't show up
