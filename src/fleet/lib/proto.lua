-- Protocol constants shared by every fleet program.

local P = {}

P.PROTOCOL = "turtlegps"   -- rednet protocol name
P.VERSION = 1              -- envelope format version
P.BROADCAST = -1           -- envelope "to" value for broadcasts

-- Message types. Every body is a table { type = ..., dim = <sender's dimension>, ... }.
P.HB = "hb"                -- turtle -> server: heartbeat / telemetry
P.HB_ACK = "hb_ack"        -- server -> turtle: heartbeat acknowledged (+ queued commands later)
P.VIEW_REQ = "view_req"    -- ui client -> server: give me the map view for a dimension
P.VIEW = "view"            -- server -> ui client
P.ACTION = "action"        -- ui client -> server: forget turtle, ack alert, ... (allowlisted)
P.ACTION_R = "action_r"    -- server -> ui client: result of an action
P.ALERT = "alert"          -- server -> ui clients: a new alert was raised
P.UPD_OFFER = "upd_offer"  -- server -> all: new code version available
P.UPD_REQ = "upd_req"      -- device -> server: send me the files I am missing
P.UPD_FILE = "upd_file"    -- server -> device: one file
P.UPD_END = "upd_end"      -- server -> device: manifest, all files sent

-- Headings: 0 = north (-z), 1 = east (+x), 2 = south (+z), 3 = west (-x)
P.HEADING_NAME = { [0] = "N", [1] = "E", [2] = "S", [3] = "W" }
P.DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
P.DZ = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }

function P.headingFromDelta(dx, dz)
  if dx == 0 and dz == -1 then return 0 end
  if dx == 1 and dz == 0 then return 1 end
  if dx == 0 and dz == 1 then return 2 end
  if dx == -1 and dz == 0 then return 3 end
  return nil
end

-- Dimensions. Canonical ids drop the "minecraft:" prefix.
P.DIM_ORDER = { "overworld", "the_nether", "the_end" }

local aliases = {
  overworld = "overworld", ow = "overworld", world = "overworld",
  nether = "the_nether", the_nether = "the_nether",
  ["end"] = "the_end", the_end = "the_end",
}

function P.normDim(d)
  if type(d) ~= "string" or d == "" then return nil end
  d = d:lower()
  local short = d:match("^minecraft:(.+)$") or d
  return aliases[short] or d
end

local labels = { overworld = "Overworld", the_nether = "Nether", the_end = "End" }

function P.dimLabel(d)
  if not d then return "Unknown" end
  if labels[d] then return labels[d] end
  local s = d:match(":(.+)$") or d
  return (s:gsub("_", " "):gsub("^%l", string.upper))
end

local shorts = { overworld = "OVR", the_nether = "NTH", the_end = "END" }

function P.dimShort(d)
  if shorts[d] then return shorts[d] end
  return P.dimLabel(d):sub(1, 3):upper()
end

return P
