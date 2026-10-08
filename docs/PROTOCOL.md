# Protocol and security

All fleet traffic is rednet over ender modems, protocol name `turtlegps`.

## Envelope

```lua
{
  v  = 1,                 -- envelope version
  f  = 12,                -- sender computer ID
  t  = 7,                 -- recipient ID, or -1 for broadcast
  ts = 1760000000000,     -- os.epoch("utc") in ms
  n  = "1a.3f9e2c",       -- nonce (sequence.random)
  b  = '{dim="the_nether",type="hb",...}', -- serialized body
  m  = "<64 hex>",        -- HMAC-SHA256(secret, "v|f|t|ts|n|b")
}
```

A receiver drops a message, without replying, if any of these hold:

- the protocol isn't `turtlegps`, or the message isn't addressed to it
- a field is missing or malformed, or the body is larger than the size limit
- `f` doesn't match the rednet sender
- `|now - ts|` is more than `replayWindow` (30 s)
- it has already seen `f:n` within that window (a replay)
- the HMAC doesn't match (no secret, or a different secret)

Only after the HMAC checks out is the body unserialized, with an empty environment.

Every body has `type` and `dim` (the sender's dimension).

## Who may do what

| Message | Accepted from |
|---|---|
| `hb` (turtle heartbeat) | any computer with the secret; optionally only IDs in `turtles` |
| `hb` (`role = "gpshost"` / `"pocket"`) | any computer with the secret |
| `action`, `view_req` (and commands from milestone 3) | IDs in `commanders` only |
| `upd_req` | any computer with the secret |
| anything to a turtle, GPS host or pocket | only the control computer (`serverId`) |

## Message types (milestone 1)

| type | direction | fields |
|---|---|---|
| `hb` | turtle → control | `role="turtle"`, `label`, `x y z`, `h` (0=N 1=E 2=S 3=W), `fix` (`gps`/`dr`/`none`), `fixAge`, `gpsErr`, `fuel` (-1 = unlimited), `fuelMax`, `reserve`, `inv={used,total}`, `status`, `job`, `msg`, `ver`, `up` |
| `hb` | GPS host → control | `role="gpshost"`, `x y z`, `served`, `verdict`, `ver` |
| `hb_ack` | control → device | `ver` (the control's code version) |
| `view_req` / `view` | pocket ↔ control | map data for one dimension |
| `action` / `action_r` | pocket ↔ control | `op` = `forget`, `ack`, `ackAll` |
| `upd_offer` | control → all | `ver` |
| `upd_req` | device → control | `have = { [path] = sha256 }` |
| `upd_file` | control → device | `path`, `data`, `hash` |
| `upd_end` | control → device | `files = { [path] = sha256 }`, `ver` |

## GPS

GPS uses the standard GPS channel (65534). Our hosts reply `{ x, y, z, dim = "the_nether" }`.
Ender modems deliver messages from other dimensions without a distance, and those can't be
used for a position fix. So only hosts in your own dimension count, and the reply also tells
you which dimension that is. The position is solved by least squares over every host heard,
and a mistyped host is detected from the residual.

## Limits of the security model

- **Signed, not encrypted.** Other players who listen on the right channels can read turtle
  positions, including where your bases are. They can't command your fleet, fake turtles or
  replay old messages. Encryption can be added later if you want it.
- **A stolen device holds the secret.** If someone picks up one of your turtles or pockets,
  set a new secret on everything. If you use the `turtles` allowlist, that limits the damage.
- **Flooding:** oversized messages are dropped before any hashing, so spam costs little CPU.
