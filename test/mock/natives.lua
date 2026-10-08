-- luacheck: globals string
-- "Real ROM" mode: the Java-side natives CC:Tweaked gives the Lua VM, so the actual
-- CraftOS bios.lua, shell, multishell, rednet daemon, require, parallel and window
-- can run on top. Enable with CC_ROM=<path to .../computercraft/lua> (see
-- tools/fetch_rom.sh). Only natives live here; everything else is CraftOS's own Lua.

local makeTurtle = require("mock.turtle")

local SIDES = { "top", "bottom", "left", "right", "front", "back" }

-- Cobalt (like Lua 5.1) accepts "%." in gsub replacement strings; PUC Lua 5.2 raises
-- "invalid use of '%' in replacement string". CraftOS' require.lua relies on it.
if not string.__cobaltGsub then
  local rawgsub = string.gsub
  string.gsub = function(s, pat, repl, n)
    if type(repl) == "string" and repl:find("%", 1, true) then
      repl = rawgsub(repl, "%%(.)", function(ch)
        if ch:match("[%d%%]") then return "%" .. ch end
        return ch
      end)
    end
    return rawgsub(s, pat, repl, n)
  end
  string.__cobaltGsub = true
end

local function utf8shim()
  local u = {}
  function u.char(...)
    local out = {}
    for i = 1, select("#", ...) do
      local cp = select(i, ...)
      if cp < 0x80 then out[#out + 1] = string.char(cp)
      elseif cp < 0x800 then out[#out + 1] = string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
      else
        out[#out + 1] = string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
      end
    end
    return table.concat(out)
  end
  function u.codes(s)
    local i = 1
    return function()
      if i > #s then return nil end
      local p = i
      i = i + 1
      return p, s:byte(p)
    end
  end
  u.charpattern = "[\0-\x7F\xC2-\xF4][\x80-\xBF]*"
  return u
end

return function(sim, c)
  local G = {}
  for _, k in ipairs({ "assert", "error", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget",
    "rawlen", "rawset", "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type", "xpcall" }) do
    G[k] = _G[k]
  end
  G.string, G.table, G.math, G.bit32 = string, table, math, bit32
  G.utf8 = utf8shim()
  G._VERSION = _VERSION
  G._HOST = "ComputerCraft 1.120.2 (TurtleGPS mock, real CraftOS ROM)"
  G._CC_DEFAULT_SETTINGS = ""
  G.load = function(chunk, name, mode, env) return load(chunk, name, mode, env or G) end
  G.loadstring = function(s, name) return load(s, name, "t", G) end
  G._G = G

  local co = {}
  for k, v in pairs(coroutine) do co[k] = v end
  function co.create(fn)
    local th = coroutine.create(fn)
    if c.hook then debug.sethook(th, c.hook, "", 1000) end
    return th
  end
  function co.wrap(fn)
    local th = co.create(fn)
    return function(...)
      local r = table.pack(coroutine.resume(th, ...))
      if not r[1] then error(r[2], 0) end
      return table.unpack(r, 2, r.n)
    end
  end
  G.coroutine = co
  G.debug = {
    traceback = debug.traceback, getinfo = debug.getinfo, getlocal = debug.getlocal,
    getupvalue = debug.getupvalue, getregistry = debug.getregistry, getmetatable = debug.getmetatable,
    setmetatable = debug.setmetatable,
  }

  -- os natives (bios.lua adds pullEvent, sleep, version, loadAPI, ...)
  G.os = {
    getComputerID = function() return c.id end,
    computerID = function() return c.id end,
    getComputerLabel = function() return c.label end,
    computerLabel = function() return c.label end,
    setComputerLabel = function(l) c.label = l end,
    clock = function() return sim.t - c.bootTime end,
    epoch = function(kind)
      if kind == "utc" or kind == "local" then return math.floor(sim.epoch0 + sim.t * 1000) end
      return math.floor((6000 + sim.t * 20) * 3600)
    end,
    time = function() return (6 + sim.t / 50) % 24 end,
    day = function() return 1 + math.floor((6 + sim.t / 50) / 24) end,
    date = function(fmt, t) return os.date(fmt, t or math.floor(sim.epoch0 / 1000 + sim.t)) end,
    startTimer = function(secs) return sim:startTimer(c, secs) end,
    cancelTimer = function(id) sim:cancelTimer(c, id) end,
    setAlarm = function() return sim:startTimer(c, 3600) end,
    cancelAlarm = function() end,
    queueEvent = function(...) sim:queue(c, table.pack(...)) end,
    shutdown = function() sim:requestShutdown(c) end,
    reboot = function() sim:requestReboot(c) end,
  }

  -- term native
  local t = c.screen:api()
  t.nativePaletteColour = function() return 0, 0, 0 end
  t.nativePaletteColor = t.nativePaletteColour
  G.term = t

  -- fs native (ROM mounted read-only at /rom by the FS object)
  local fs_ = c.fs:api()
  fs_.getDrive = function(p)
    if not fs_.exists(p) then return nil end
    return fs_.combine(p):match("^rom") and "rom" or "hdd"
  end
  fs_.attributes = function(p)
    if not fs_.exists(p) then error("/" .. fs_.combine(p) .. ": No such file", 2) end
    local dir = fs_.isDir(p)
    return { size = dir and 0 or fs_.getSize(p), isDir = dir, isReadOnly = fs_.isReadOnly(p),
      created = 0, modified = 0, modification = 0 }
  end
  G.fs = fs_

  -- peripheral native: the six sides only; peripheral.lua adds names, wrap, find
  local function at(side) return c.peripherals[side] end
  G.peripheral = {
    isPresent = function(side) return at(side) ~= nil end,
    getType = function(side) local p = at(side); return p and p.type or nil end,
    hasType = function(side, ty) local p = at(side); return p ~= nil and p.type == ty end,
    getMethods = function(side)
      local p = at(side)
      if not p then return nil end
      local out = {}
      for k in pairs(p.methods) do out[#out + 1] = k end
      table.sort(out)
      return out
    end,
    call = function(side, method, ...)
      local p = at(side)
      if not p then error("No peripheral attached", 2) end
      local f = p.methods[method]
      if not f then error("No such method " .. tostring(method), 2) end
      return f(...)
    end,
  }

  local rs = {
    getSides = function() return { table.unpack(SIDES) } end,
    getInput = function() return false end, setOutput = function() end, getOutput = function() return false end,
    getAnalogInput = function() return 0 end, setAnalogOutput = function() end, getAnalogOutput = function() return 0 end,
    getAnalogueInput = function() return 0 end, setAnalogueOutput = function() end, getAnalogueOutput = function() return 0 end,
    getBundledInput = function() return 0 end, getBundledOutput = function() return 0 end,
    setBundledOutput = function() end, testBundledInput = function() return false end,
  }
  G.redstone, G.rs = rs, rs

  if c.kind == "turtle" then G.turtle = makeTurtle(sim, c) end
  if c.kind == "pocket" then G.pocket = { equipBack = function() return false end, unequipBack = function() return false end } end
  return G
end
