-- Loads /fleet/config.lua (a Lua file returning a table) and fills in defaults per role.
-- Edit it in-game with:  edit /fleet/config.lua

local U = require("lib.util")

local C = {}
C.PATH = "/fleet/config.lua"
C.DATA = "/fleet/data"

C.DEFAULTS = {
  all = {
    role = nil,          -- "control" | "turtle" | "pocket" | "gpshost"
    secret = nil,        -- shared secret, identical on every fleet computer
    serverId = nil,      -- computer ID of the control-room computer
    dim = nil,           -- this computer's dimension (turtles/gps hosts/control)
    replayWindow = 30,   -- seconds a signed message stays valid
  },
  turtle = {
    heartbeat = 3,       -- seconds between heartbeats
    gpsEvery = 60,       -- seconds between GPS re-fixes while idle
    reservedSlots = { 16 }, -- slot 16 holds the swap tool (pickaxe <-> modem)
    lowFuel = 500,       -- report low fuel below this (plus distance home)
  },
  control = {
    dim = "overworld",
    commanders = {},     -- computer IDs allowed to send commands (pockets, extra UIs)
    turtles = nil,       -- optional allowlist of turtle IDs; nil = any computer with the secret
    staleAfter = 12,     -- seconds without heartbeat before a turtle is shown stale
    lostAfter = 45,      -- seconds without heartbeat before a turtle is LOST (alert)
    lowFuel = 500,
    owner = nil,         -- player name for Chat Box alerts
    monitor = { side = nil, scale = 0.5 },
    garages = {},        -- [dim] = { x = , y = , z = }  shown on the map
    ui = { ascii = false },
  },
  pocket = {
    owner = nil,         -- your player name (matches Player Detector results)
    refresh = 2,
    ui = { ascii = false },
  },
  gpshost = {
    x = nil, y = nil, z = nil,
  },
}

local function readConfigFile(path)
  if not fs.exists(path) then return nil, "missing" end
  local h = fs.open(path, "r")
  local src = h.readAll()
  h.close()
  local fn, err = load(src, "=config", "t", {})
  if not fn then return nil, err end
  local ok, t = pcall(fn)
  if not ok then return nil, t end
  if type(t) ~= "table" then return nil, "config.lua must return a table" end
  return t
end

--- Returns config table (with defaults) or nil plus an error.
function C.load(path)
  local t, err = readConfigFile(path or C.PATH)
  if not t then return nil, err end
  U.merge(t, C.DEFAULTS.all)
  if t.role and C.DEFAULTS[t.role] then U.merge(t, C.DEFAULTS[t.role]) end
  return t
end

--- Lists human readable problems with a config.
function C.problems(cfg)
  local p = {}
  local roles = { control = true, turtle = true, pocket = true, gpshost = true }
  if not roles[cfg.role] then p[#p + 1] = "role must be control, turtle, pocket or gpshost" end
  if type(cfg.secret) ~= "string" or #cfg.secret < 8 then
    p[#p + 1] = "secret must be at least 8 characters"
  end
  if cfg.role ~= "control" and type(cfg.serverId) ~= "number" then
    p[#p + 1] = "serverId must be the control computer's ID"
  end
  if cfg.role == "gpshost" then
    if type(cfg.x) ~= "number" or type(cfg.y) ~= "number" or type(cfg.z) ~= "number" then
      p[#p + 1] = "gpshost needs x, y, z of this computer"
    end
    if not cfg.dim then p[#p + 1] = "gpshost needs dim" end
  end
  return p
end

-- Readable Lua output so the file stays hand-editable.
local function pretty(v, indent)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t ~= "table" then return tostring(v) end
  local pad = string.rep("  ", indent + 1)
  local parts = {}
  local n = #v
  for i = 1, n do parts[#parts + 1] = pad .. pretty(v[i], indent + 1) end
  for _, k in ipairs(U.sortedKeys(v)) do
    if not (type(k) == "number" and k >= 1 and k <= n) then
      local key = (type(k) == "string" and k:match("^[%a_][%w_]*$")) and k or ("[" .. pretty(k, 0) .. "]")
      parts[#parts + 1] = pad .. key .. " = " .. pretty(v[k], indent + 1)
    end
  end
  if #parts == 0 then return "{}" end
  return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. string.rep("  ", indent) .. "}"
end

function C.save(cfg, path)
  path = path or C.PATH
  local keep = {}
  local defaults = C.DEFAULTS[cfg.role] or {}
  for k, v in pairs(cfg) do
    -- only write keys that differ from defaults, so new defaults reach old installs
    local d = defaults[k]
    if d == nil then d = C.DEFAULTS.all[k] end
    if type(v) == "table" or v ~= d then keep[k] = v end
  end
  local h = fs.open(path, "w")
  h.write("-- TurtleGPS fleet config. Same secret on every fleet computer.\n")
  h.write("return " .. pretty(keep, 0) .. "\n")
  h.close()
end

C.pretty = pretty

return C
