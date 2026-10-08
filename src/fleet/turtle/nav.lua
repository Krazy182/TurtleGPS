-- Turtle position tracking: dead reckoning on every move, corrected by GPS fixes.
-- All movement must go through these functions so the tracked position stays right.
--
-- Heading: 0 = north (-z), 1 = east (+x), 2 = south (+z), 3 = west (-x).

local P = require("lib.proto")
local U = require("lib.util")
local locate = require("lib.locate")
local ser = require("lib.ser")
local store = require("lib.store")

local Nav = {}
Nav.__index = Nav

--- opts: log, dim (configured dimension or nil for auto), path (persist file)
function Nav.new(opts)
  return setmetatable({
    log = opts.log,
    cfgDim = P.normDim(opts.dim),
    dim = P.normDim(opts.dim),
    path = opts.path or "/fleet/data/nav",
    x = nil, y = nil, z = nil, h = nil,
    fixAt = nil,      -- epoch ms of the last GPS fix
    src = "none",     -- "gps" right after a fix, "dr" after dead-reckoned moves, "none" unknown
    moves = 0,        -- moves since the last fix
    gpsErr = nil,     -- why the last GPS attempt failed
    drift = nil,      -- last correction a GPS fix applied (blocks), for diagnostics
  }, Nav)
end

function Nav:known() return self.x ~= nil end

function Nav:pos() return { x = self.x, y = self.y, z = self.z } end

function Nav:save()
  -- tiny file, written after every move so a reboot resumes in the right place
  local h = fs.open(self.path, "w")
  if h then
    h.write(ser.serialize({ x = self.x, y = self.y, z = self.z, h = self.h, dim = self.dim }))
    h.close()
  end
end

function Nav:load()
  local s = store.load(self.path, nil)
  if type(s) == "table" then
    self.x, self.y, self.z, self.h = s.x, s.y, s.z, s.h
    if not self.cfgDim then self.dim = s.dim end
    if self.x then self.src = "dr" end
  end
end

--- Asks the GPS constellation where we are. Returns the locate result or nil, err.
function Nav:fix(timeout)
  local p, err = locate.locate(timeout or 2)
  if not p then
    self.gpsErr = err
    return nil, err
  end
  self.gpsErr = nil
  if p.dim then
    if self.cfgDim and p.dim ~= self.cfgDim and self.log then
      self.log:warn("GPS hosts say %s but config says %s; using GPS", p.dim, self.cfgDim)
    end
    self.dim = p.dim
  end
  if self.x and (p.bx ~= self.x or p.by ~= self.y or p.bz ~= self.z) then
    self.drift = math.abs(p.bx - self.x) + math.abs(p.by - self.y) + math.abs(p.bz - self.z)
    if self.log then
      self.log:warn("GPS corrected position by %d (was %s)", self.drift, U.fmtPos(self))
    end
  end
  self.x, self.y, self.z = p.bx, p.by, p.bz
  self.fixAt = os.epoch("utc")
  self.src = "gps"
  self.moves = 0
  self:save()
  return p
end

local function sameBlock(a, b) return a.bx == b.bx and a.by == b.by and a.bz == b.bz end

--- Works out which way we face by moving one block and asking GPS again.
--- Skipped when we are exactly where we were saved (heading is still valid then).
function Nav:calibrate()
  local saved = self.x and { x = self.x, y = self.y, z = self.z, h = self.h }
  local p0, err = self:fix()
  if not p0 then return false, "no GPS: " .. tostring(err) end
  if saved and saved.h and saved.x == p0.bx and saved.y == p0.by and saved.z == p0.bz then
    self.h = saved.h
    return true, "kept saved heading"
  end
  self.h = nil
  local fuel = turtle.getFuelLevel()
  if fuel ~= "unlimited" and fuel < 2 then return false, "need 2 fuel to find heading" end

  -- forward, back, then the same after a right turn: covers all four directions
  local tries = {
    { move = turtle.forward, undo = turtle.back, sign = 1 },
    { move = turtle.back, undo = turtle.forward, sign = -1 },
  }
  for turn = 0, 1 do
    if turn == 1 then turtle.turnRight() end
    for _, t in ipairs(tries) do
      if t.move() then
        local p1 = locate.locate(2)
        local undone = t.undo()
        if not p1 then
          self.x = nil
          return false, "lost GPS while calibrating"
        end
        local h = P.headingFromDelta((p1.bx - p0.bx) * t.sign, (p1.bz - p0.bz) * t.sign)
        if not h then return false, "unexpected GPS delta" end
        self.h = h
        if not undone then self.x, self.y, self.z = p1.bx, p1.by, p1.bz end
        self.src = "gps"
        self:save()
        return true, "heading " .. P.HEADING_NAME[h]
      end
    end
  end
  return false, "boxed in: cannot move to find heading"
end

-- Tracked movement --------------------------------------------------------------

local function after(self, ok)
  if ok then
    self.moves = self.moves + 1
    if self.src == "gps" then self.src = "dr" end
    self:save()
  end
  return ok
end

function Nav:forward()
  local ok, err = turtle.forward()
  if ok then
    if self.h and self.x then
      self.x, self.z = self.x + P.DX[self.h], self.z + P.DZ[self.h]
    else
      self.x = nil -- moved without knowing where we face: position unknown until next fix
    end
  end
  return after(self, ok), err
end

function Nav:back()
  local ok, err = turtle.back()
  if ok then
    if self.h and self.x then
      self.x, self.z = self.x - P.DX[self.h], self.z - P.DZ[self.h]
    else
      self.x = nil
    end
  end
  return after(self, ok), err
end

function Nav:up()
  local ok, err = turtle.up()
  if ok and self.y then self.y = self.y + 1 end
  return after(self, ok), err
end

function Nav:down()
  local ok, err = turtle.down()
  if ok and self.y then self.y = self.y - 1 end
  return after(self, ok), err
end

function Nav:turnLeft()
  local ok, err = turtle.turnLeft()
  if ok and self.h then self.h = (self.h + 3) % 4; self:save() end
  return ok, err
end

function Nav:turnRight()
  local ok, err = turtle.turnRight()
  if ok and self.h then self.h = (self.h + 1) % 4; self:save() end
  return ok, err
end

--- Turns to face heading h (fewest turns).
function Nav:face(h)
  if not self.h then return false, "heading unknown" end
  local d = (h - self.h) % 4
  if d == 1 then return self:turnRight()
  elseif d == 2 then self:turnRight(); return self:turnRight()
  elseif d == 3 then return self:turnLeft() end
  return true
end

--- Snapshot for heartbeats.
function Nav:telemetry()
  local now = os.epoch("utc")
  return {
    x = self.x, y = self.y, z = self.z, h = self.h, dim = self.dim,
    fix = self.x and self.src or "none",
    fixAge = self.fixAt and math.floor((now - self.fixAt) / 1000) or nil,
    moves = self.moves,
    gpsErr = self.gpsErr,
  }
end

return Nav
