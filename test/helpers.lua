-- Assertions and fleet-building helpers for the mock tests.

local Sim = require("mock.sim")

local H = {}

local function show(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

function H.eq(a, b, msg)
  if a ~= b then error((msg or "values differ") .. ": expected " .. show(b) .. ", got " .. show(a), 2) end
end

function H.ok(v, msg)
  if not v then error(msg or "expected truthy value", 2) end
  return v
end

function H.near(a, b, eps, msg)
  if type(a) ~= "number" or math.abs(a - b) > (eps or 1e-6) then
    error((msg or "not near") .. ": expected " .. show(b) .. ", got " .. show(a), 2)
  end
end

--- Fails if any computer crashed: harness-level errors, TurtleGPS crash logs, or an
--- error left on screen (in real-ROM mode CraftOS' shell prints errors itself).
function H.noErrors(sim)
  for id, c in pairs(sim.computers) do
    local crash = c.fs:readFile("/fleet/data/crash.txt")
    if crash and not c.allowCrash then sim.errors[#sim.errors + 1] = { id = id, err = "crash.txt: " .. crash } end
    if c.screen:contains("TurtleGPS crashed") and not c.allowCrash then
      sim.errors[#sim.errors + 1] = { id = id, err = "screen: " .. c.screen:dumpText() }
    end
  end
  if #sim.errors > 0 then
    local lines = {}
    for i, e in ipairs(sim.errors) do
      if i > 3 then lines[#lines + 1] = "... and " .. (#sim.errors - 3) .. " more"; break end
      lines[#lines + 1] = "#" .. e.id .. ": " .. tostring(e.err):sub(1, 1500)
    end
    error("computers reported errors:\n" .. table.concat(lines, "\n"), 2)
  end
end

--- Loads a /fleet module inside computer c's environment (for non-yielding calls).
function H.lib(c, name)
  -- a separate light-mode environment bound to c, so this works in real-ROM mode too
  if not c.libEnv then
    c.bootTime = c.bootTime or 0
    c.libEnv = require("mock.env")(c.sim or H.lastSim, c)
  end
  local env = setmetatable({}, { __index = c.libEnv })
  env.require, env.package = c.libEnv.__mock.makeRequire(env, "/")
  env.package.path = "/fleet/?.lua;" .. env.package.path
  return env.require(name)
end

local cfgSer
function H.configText(t)
  cfgSer = cfgSer or dofile("src/fleet/lib/ser.lua")
  return "return " .. cfgSer.serialize(t) .. "\n"
end

H.SECRET = "correct-horse-battery"

--- Adds 4 GPS host computers for a dimension around (ox, oy, oz).
function H.gps(sim, dim, ox, oy, oz, firstId, extra)
  local spots = { { 0, 0, 0 }, { 8, 0, 0 }, { 0, 0, 8 }, { 0, 8, 0 } }
  if extra then spots[#spots + 1] = { 8, 8, 8 } end
  local hosts = {}
  for i, s in ipairs(spots) do
    local x, y, z = ox + s[1], oy + s[2], oz + s[3]
    hosts[i] = sim:add({
      id = firstId + i - 1, dim = dim, pos = { x, y, z },
      peripherals = { top = { "modem", ender = true } },
      files = { ["/fleet/config.lua"] = H.configText({
        role = "gpshost", secret = H.SECRET, serverId = 1, dim = dim, x = x, y = y, z = z,
      }) },
    })
  end
  return hosts
end

--- Standard fleet: control #1 (overworld, 8x6 monitor), GPS in 3 dims, one turtle per dim.
function H.fleet(opts)
  opts = opts or {}
  local sim = Sim.new({ verbose = opts.verbose })
  sim:player("Steve", 3.5, 65, -10.5, "overworld") -- the owner, online for chat alerts
  local controlCfg = {
    role = "control", secret = H.SECRET, dim = "overworld", commanders = { 50 },
    owner = "Steve", lostAfter = 45, staleAfter = 12,
    garages = { overworld = { x = 0, y = 65, z = 0 }, the_nether = { x = 0, y = 70, z = 0 } },
  }
  for k, v in pairs(opts.control or {}) do controlCfg[k] = v end
  sim.control = sim:add({
    id = 1, label = "Control", dim = "overworld", pos = { 0, 70, -20 },
    peripherals = {
      back = { "modem", ender = true }, top = { "monitor", w = opts.monW or 8, h = opts.monH or 5 },
      left = { "playerDetector" }, right = { "chatBox" }, bottom = { "speaker" },
    },
    files = { ["/fleet/config.lua"] = H.configText(controlCfg) },
  })
  if opts.gps ~= false then
    H.gps(sim, "overworld", 0, 90, 0, 100)
    H.gps(sim, "the_nether", 0, 60, 0, 110)
    H.gps(sim, "the_end", 0, 70, 0, 120)
  end
  sim.turtles = {}
  for _, t in ipairs(opts.turtles or {
    { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 },
    { id = 11, dim = "the_nether", pos = { 3, 50, -4 }, heading = 2 },
    { id = 12, dim = "the_end", pos = { -6, 61, 2 }, heading = 0 },
  }) do
    sim.turtles[#sim.turtles + 1] = H.turtle(sim, t)
  end
  return sim
end

function H.turtle(sim, t)
  local cfg = { role = "turtle", secret = H.SECRET, serverId = 1, dim = t.cfgDim or t.dim }
  for k, v in pairs(t.config or {}) do cfg[k] = v end
  return sim:add({
    id = t.id, kind = "turtle", label = t.label or ("T" .. t.id), dim = t.dim, pos = t.pos,
    heading = t.heading or 0, fuel = t.fuel or 2000,
    equip = t.equip or { left = "advancedperipherals:chunk_controller", right = "computercraft:wireless_modem_advanced" },
    inv = t.inv or { [16] = { name = "minecraft:diamond_pickaxe", count = 1 } },
    files = { ["/fleet/config.lua"] = H.configText(cfg) },
    boot = t.boot,
  })
end

--- Fake http API for computer c. responder(url, body) returns the response text.
--- Works in light mode (post) and real-ROM mode (native request + http_success event).
function H.fakeHttp(sim, c, responder)
  local function handle(text)
    return { readAll = function() return text end, close = function() end,
      getResponseCode = function() return 200 end }
  end
  c.http = {
    post = function(url, body) return handle(responder(url, body)) end,
    request = function(url, body)
      if type(url) == "table" then url, body = url.url, url.body end
      sim:queue(c, table.pack("http_success", url, handle(responder(url, body))))
      return true
    end,
    checkURL = function() return true end,
  }
end

H.Sim = Sim
return H
