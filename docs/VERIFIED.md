# What was checked against the real source

The things the code relies on were checked against the source code of the mods, not
written from memory:

- **CC:Tweaked 1.120.2**, commit `c8b3f6af` (mc-1.20.x)
- **Advanced Peripherals**, branch `dev/1.20.1`

The test harness can also boot the real CraftOS ROM (see [TESTING.md](TESTING.md)), and the
whole suite passes that way too.

## CC:Tweaked

| Fact | Where | Consequence here |
|---|---|---|
| `term.write` / `term.blit` draw every byte as-is, with no filtering of control characters | `TermMethods.java`, `Terminal.java` | Map icons use font codes 1-31 |
| Font: 16 ►, 17 ◄, 30 ▲, 31 ▼, 24-27 thin arrows, 7 bullet, 2 face, 4 diamond, 164 ¤. **127 is a checkerboard, 15 is a music note** | `term_font.png` | Garage is drawn as `G`, GPS hosts as `¤` |
| Stock `gps.locate` accepts any reply where `#msg == 3`; it treats hosts within **1 block** of each other as one | `rom/apis/gps.lua` | Our `{x, y, z, dim=...}` replies work with stock GPS |
| The stock gps host answers only pings that carry a distance (same dimension) | `rom/programs/gps.lua` | Same rule in `gpshost` |
| Ender modems deliver to other dimensions **without** a distance | `WirelessNetwork.java` | Only same-dimension hosts can give a fix |
| A pocket computer's modem position is the player's **eye** position | `PocketHolder.java` | "Come to me" (milestone 3) must subtract eye height |
| Monitor size = `round((blocks - 0.3125) / (scale * 6/64))` wide, `9/64` tall | `ServerMonitor.java` | Auto text-scale choice; mock monitor sizes |
| At most **256** queued events per computer; extra events are dropped | `ComputerExecutor.java` | Mock enforces it; the stress test checks for none dropped |
| `rednet.run` takes the sender ID from the message (`nSender`) and ignores a repeated message ID for ~10 s | `rom/apis/rednet.lua` | The sender can be faked, so the HMAC is what proves who sent it |
| CraftOS `require.lua` uses `"%."` in a gsub replacement, which Cobalt allows but PUC Lua 5.2 rejects | `require.lua` | The mock makes gsub lenient the way Cobalt is |
| Turtle commands yield until a `turtle_response` event; other `mainThread` peripheral calls yield until `task_complete` | `LuaContext.java`, `TaskCallback.java` | Events reaching that coroutine meanwhile are lost; the mock does the same |

## Advanced Peripherals

| Fact | Consequence here |
|---|---|
| Every Chat Box and Player Detector method is `mainThread = true` and takes a server tick | Calls run in their own coroutine |
| `sendMessageToPlayer(msg, player, prefix, ...)` returns `true`; or `nil, "incorrect player name/uuid"` when the player is offline; or `false, "NOT_SAME_DIMENSION"`; and it has an operation cooldown | Retry only on cooldown and drop the rest, so an offline owner can't block later alerts |
| `sendToastToPlayer(msg, title, player, prefix, ...)` | Used for LOST/stuck alerts |
| `getPlayerPos(name)` **throws** if the server disables `playerSpy`; for an unknown or offline player it returns an **empty table** plus `"PLAYER_NOT_FOUND"`, not nil; coordinates are the floored feet position; the server can add deliberate noise (`playerSpyRandError`) | Milestone 2 must `pcall`, check for `x`, and fall back to pocket GPS |
| `chunkyTurtleRadius` defaults to 0: a Chunky Turtle loads only its own chunk | All 4 GPS hosts go in one chunk with one Chunky Turtle |
