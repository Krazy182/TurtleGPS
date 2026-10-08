# Setup

## What you need

### Every dimension (Overworld, Nether, End)

| Thing | Hardware | Notes |
|---|---|---|
| GPS constellation | 4 computers, each with an **ender modem**. Make **one of them a Chunky Turtle** (or use a chunk loader). | All four sit in one chunk that must stay loaded, see below. |
| Turtles | Turtle with the **Chunky Turtle upgrade** on one side and an **ender modem** on the other. A **diamond pickaxe in slot 16**. Some fuel. | Slot 16 is reserved, see the tool-swap note. |
| Garage | Just a spot for now. Put its coordinates in the control config so it shows on the map. | Garage behaviour starts in milestone 3. |

### Control room (any dimension, usually the Overworld)

- Advanced computer with an **ender modem** (required).
- **Advanced monitor**, as big as you like. 8x5 or 8x6 blocks works well at text scale 0.5.
- Optional: **Chat Box** (alerts sent to you privately in chat), a **speaker** (chime),
  and a **Player Detector** (used from milestone 2).
- The control room must stay loaded. Put it in the spawn chunks, or in the same chunk as
  your Overworld GPS constellation so its Chunky Turtle keeps both loaded.

### Pocket computers (milestone 2)

Advanced pocket computer with an ender modem. You can install it now: it checks in with the
control computer and picks up the pocket map by over-the-air update when milestone 2 lands.
Note its computer ID: it goes on the control's `commanders` allowlist.

> **Tool-swap note (affects how you build turtles).** A turtle has only two upgrade slots.
> The Chunky upgrade and the ender modem fill both, so there is no room for a pickaxe. From
> milestone 3 on, turtles swap the ender modem and the pickaxe in slot 16 while they dig, and
> swap back to report in. That is why slot 16 is reserved and inventory shows "x / 15 slots".
> A mining pickaxe also breaks logs and crops, so one tool covers mining, chopping and farming.

## GPS constellation placement

Ender modems have unlimited range inside a dimension, so the hosts can sit right next to your
base. What matters:

1. **All 4 hosts in the same chunk, and that chunk must always be loaded.** If the hosts'
   chunk unloads when you walk away, every turtle in that dimension loses GPS. Make one host a
   Chunky Turtle running the gpshost role: it keeps its own chunk loaded, and that keeps the
   other three running. The Nether and the End have no spawn chunks, so this matters most there.
2. **Not all at the same height.** Three hosts on one level plus one directly above is ideal.
   If all four are on one plane, GPS gives two mirror-image answers.
3. **At least 6 blocks apart.** Recent CC:Tweaked versions of `gps.locate` treat hosts
   closer than 5 blocks as duplicates. TurtleGPS's own locator doesn't, but other programs
   might use the stock one.
4. Each host's coordinates are **the block the computer occupies**. Press F3, look at the
   computer, and read "Targeted Block".

Recommended layout, where `X0, Z0` is the chunk's north-west corner (both multiples of 16) and
`Y` is any height you like:

```
 host  x        y      z         notes
 H1    X0+2     Y      Z0+2      the Chunky Turtle (keeps the chunk loaded)
 H2    X0+10    Y      Z0+2
 H3    X0+2     Y      Z0+10
 H4    X0+2     Y+8    Z0+2      straight above H1
 (H5   X0+10    Y+8    Z0+10)    optional 5th host: lets GPS ignore one mistyped host
```

Side view (looking north) and top view:

```
  H4                         z
  |                    Z0+2  H1 ------- H2
  | 8 blocks                  |
  |                           | 8 blocks
  H1 -------- H2       Z0+10  H3
     8 blocks                X0+2      X0+10   x
```

- **Nether:** stay below the bedrock roof (y < 120) so you can reach them. Any lava-free
  spot near your Nether garage is fine.
- **End:** on the main island or wherever your End garage is, on solid blocks.

When all four are running, each host's screen should say
`Check: OK: 4 hosts, good 3D spread`. If one says `MY coordinates look wrong`, re-enter that
host's coordinates with `/fleet/bin/setup`. To check from any computer, turtle or pocket in
that dimension, run `/fleet/bin/gpscheck`.

## Installing

`dist/install.lua` is a single file containing all the code. Your repository is private, so
in-game `wget` can't fetch it straight from GitHub. Use one of these:

- **pastebin (works on any server):** open `dist/install.lua` on GitHub, click *Raw*, copy
  everything, and create a new paste on pastebin.com (it's ~128 KB; the limit is 512 KB).
  Then on each computer run: `pastebin run <code>`
- **Public repo:** if you make the repo public:
  `wget run https://raw.githubusercontent.com/Krazy182/TurtleGPS/<branch>/dist/install.lua`
- **Singleplayer / server admin:** copy the file to
  `<world>/computercraft/computer/<id>/install.lua` and run `install`.

The installer writes `/fleet`, keeps any existing `/fleet/config.lua` and `/fleet/data`, and
runs setup on a fresh computer. Setup asks a few questions, writes `/fleet/config.lua` and a
`/startup.lua` that launches TurtleGPS on boot, then reboots. Paste works in CC prompts
(Ctrl+V), which helps with the secret.

### Order

1. **Control computer:** `pastebin run <code>` → role `control`, leave the secret blank to
   generate one (**write it down**), enter your dimension and your player name, and the
   pocket IDs if you have them. Then add your garages:
   `edit /fleet/config.lua`

   ```lua
   garages = {
     overworld = { x = 100, y = 64, z = -200 },
     the_nether = { x = 12, y = 70, z = -25 },
     the_end = { x = 0, y = 62, z = 30 },
   },
   ```

   Reboot (Ctrl+R held) after editing.
2. **GPS hosts (4 per dimension):** role `gpshost`, the secret, the control computer's ID,
   the dimension (`overworld`, `nether`, `end`), and this computer's x y z.
3. **Turtles:** role `turtle`, the secret, the control's ID, the dimension (or leave it blank
   to take it from GPS), and a label. On first start the turtle moves one block forward or
   back and returns to learn its heading, so leave it room and at least 2 fuel.
4. **Pockets** (optional for now): role `pocket`, the secret, the control's ID, your player
   name.

### Updating later

Reinstall only the **control computer** (`pastebin run <new code>`). It computes the code
version at boot, and every turtle, GPS host and pocket notices the new version in its next
heartbeat reply and updates itself. Busy turtles wait until they are idle. Press **U** on the
control computer's own screen to push an update immediately. If an update crashes a device 3
times in a row, that device rolls back on its own. It won't try that version again until you
press U.

## Configuration reference (`/fleet/config.lua`)

All computers:

| key | meaning |
|---|---|
| `role` | `control`, `turtle`, `pocket` or `gpshost` |
| `secret` | shared secret, the same on every fleet computer |
| `serverId` | the control computer's ID (all roles except control) |
| `dim` | dimension: `overworld`, `the_nether`, `the_end` (aliases `nether`, `end`) |
| `replayWindow` | seconds a signed message stays valid (default 30) |

Control:

| key | default | meaning |
|---|---|---|
| `commanders` | `{}` | computer IDs (pockets, extra screens) allowed to send commands |
| `turtles` | `nil` | optional allowlist of turtle IDs; `nil` = any computer with the secret |
| `owner` | `nil` | your player name: Chat Box alerts go only to you |
| `staleAfter` | `12` | seconds without a heartbeat before a turtle shows as stale |
| `lostAfter` | `45` | seconds without a heartbeat before LOST + alert |
| `lowFuel` | `500` | low-fuel alert threshold |
| `garages` | `{}` | `[dim] = { x, y, z }` |
| `monitor` | `{ scale = 0.5 }` | `side` to pick a specific monitor, `scale` = text scale |
| `ui` | `{ ascii = false }` | `ascii = true` if arrows/house icons show as `?` |

Turtle:

| key | default | meaning |
|---|---|---|
| `heartbeat` | `3` | seconds between heartbeats |
| `gpsEvery` | `60` | seconds between GPS re-fixes while idle |
| `reservedSlots` | `{ 16 }` | slots not counted as inventory (swap tool) |
| `lowFuel` | `500` | reported as the fuel reserve |

## Troubleshooting

| You see | Meaning / fix |
|---|---|
| Turtle: `Server no reply: check serverId/secret` | Wrong `serverId` or secret, or the control computer isn't running. The control's console shows `last rejected: #ID bad signature` when a secret is wrong. |
| Turtle: `Fix none: need 4 GPS hosts, heard N` | The constellation in that dimension is down or its chunk isn't loaded. Run `/fleet/bin/gpscheck`. |
| GPS host: `MY coordinates look wrong` | Re-run `/fleet/bin/setup` on that host with the right x y z. |
| GPS host: `hosts are (nearly) coplanar` | Raise or lower one host. |
| Control console: `last denied: #ID ... not in commanders allowlist` | Add that ID to `commanders`. |
| Map icons show as `?` | Set `ui = { ascii = true }` on the control computer. |
| `TurtleGPS crashed:` | It restarts by itself. Send `/fleet/data/crash.txt` (`pastebin put /fleet/data/crash.txt` gives you a link). |
