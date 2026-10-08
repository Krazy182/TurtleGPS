-- Control-room fleet state: turtles, GPS hosts, alerts, waypoints. No I/O loops here,
-- so it can be driven by app/control.lua in-game and by tests directly.

local P = require("lib.proto")
local U = require("lib.util")
local store = require("lib.store")

local Fleet = {}
Fleet.__index = Fleet
Fleet.PATH = "/fleet/data/fleet.db"

local MAX_ALERTS = 60
local GPS_LOST_AFTER = 90 -- seconds; GPS hosts heartbeat every 20s

local function num(v)
  if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then return v end
end
local function int(v)
  v = num(v)
  return v and math.floor(v)
end
local function str(v, n)
  if type(v) == "string" then return v:sub(1, n or 40) end
end
local function contains(list, v)
  if type(list) ~= "table" then return false end
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

function Fleet.new(cfg, log)
  return setmetatable({
    cfg = cfg, log = log,
    turtles = {}, gps = {}, alerts = {}, alertSeq = 0, waypoints = {},
    bootAt = os.epoch("utc"), dirty = false, savedAt = 0,
    ver = "none",
    denied = {},       -- recent refused requests, for the console
    onAlert = nil,     -- function(alert) when an alert is raised
    onResolve = nil,   -- function(alert, note) when a critical alert clears
  }, Fleet)
end

function Fleet:load()
  local d = store.load(Fleet.PATH, nil)
  if type(d) ~= "table" then return false end
  self.turtles = d.turtles or {}
  self.gps = d.gps or {}
  self.alerts = d.alerts or {}
  self.alertSeq = d.alertSeq or 0
  self.waypoints = d.waypoints or {}
  return true
end

function Fleet:save()
  local ok, err = store.save(Fleet.PATH, {
    turtles = self.turtles, gps = self.gps, alerts = self.alerts,
    alertSeq = self.alertSeq, waypoints = self.waypoints,
  })
  if ok then
    self.dirty = false
    self.savedAt = os.epoch("utc")
  elseif self.log then
    self.log:error("saving fleet state failed: %s", tostring(err))
  end
  return ok
end

function Fleet:saveIfDue(now, every)
  if self.dirty and now - self.savedAt >= (every or 10) * 1000 then self:save() end
end

function Fleet:deny(from, what, why)
  local now, key = os.epoch("utc"), from .. ":" .. what
  self.denyAt = self.denyAt or {}
  if self.denyAt[key] and now - self.denyAt[key] < 60000 then return end -- once a minute per sender
  self.denyAt[key] = now
  table.insert(self.denied, 1, { from = from, what = what, why = why, t = now })
  if #self.denied > 8 then table.remove(self.denied) end
  if self.log then self.log:warn("denied %s from #%d: %s", what, from, why) end
end

function Fleet:isCommander(id) return contains(self.cfg.commanders, id) end

-- Alerts --------------------------------------------------------------------------

function Fleet:findActive(key)
  for _, a in ipairs(self.alerts) do
    if a.key == key and a.active then return a end
  end
end

function Fleet:raise(key, kind, sev, subject, text)
  local a = self:findActive(key)
  if a then
    a.text = text
    return a
  end
  self.alertSeq = self.alertSeq + 1
  a = {
    id = self.alertSeq, key = key, kind = kind, sev = sev, text = text,
    dim = subject.dim, tid = subject.id, t = os.epoch("utc"), active = true, acked = false,
  }
  table.insert(self.alerts, 1, a)
  while #self.alerts > MAX_ALERTS do
    local victim
    for i = #self.alerts, 1, -1 do
      if not self.alerts[i].active then victim = i; break end
    end
    table.remove(self.alerts, victim or #self.alerts)
  end
  self.dirty = true
  if self.log then self.log:warn("ALERT %s", text) end
  if self.onAlert then self.onAlert(a) end
  return a
end

function Fleet:resolve(key, note)
  local a = self:findActive(key)
  if not a then return end
  a.active = false
  a.resolvedAt = os.epoch("utc")
  a.note = note
  self.dirty = true
  if self.log then self.log:info("resolved: %s%s", a.text, note and (" (" .. note .. ")") or "") end
  if a.sev >= 3 and self.onResolve then self.onResolve(a, note) end
end

function Fleet:activeAlerts()
  local out = {}
  for _, a in ipairs(self.alerts) do if a.active then out[#out + 1] = a end end
  table.sort(out, function(x, y)
    if x.acked ~= y.acked then return not x.acked end
    if x.sev ~= y.sev then return x.sev > y.sev end
    return x.t > y.t
  end)
  return out
end

-- Telemetry --------------------------------------------------------------------------

local function name(t)
  return "#" .. t.id .. (t.label and (" " .. t.label) or "")
end
Fleet.name = name

function Fleet:evaluate(t)
  local id = t.id
  if t.fuel and t.fuel >= 0 then
    local thr = math.max(self.cfg.lowFuel or 0, t.reserve or 0)
    if t.fuel < thr then
      self:raise("fuel:" .. id, "lowfuel", 2, t, ("%s low fuel: %d (want %d)"):format(name(t), t.fuel, thr))
    elseif t.fuel >= thr * 1.1 then
      self:resolve("fuel:" .. id, "refuelled")
    end
  else
    self:resolve("fuel:" .. id)
  end
  if t.invTotal and t.invTotal > 0 and t.invUsed and t.invUsed >= t.invTotal then
    self:raise("full:" .. id, "full", 2, t, name(t) .. " inventory full")
  else
    self:resolve("full:" .. id, "emptied")
  end
  if t.status == "stuck" then
    self:raise("stuck:" .. id, "stuck", 3, t,
      ("%s STUCK at %s: %s"):format(name(t), U.fmtPos(t), t.msg or "?"))
  else
    self:resolve("stuck:" .. id, "moving again")
  end
  if t.status == "error" then
    self:raise("error:" .. id, "error", 2, t, ("%s error: %s"):format(name(t), t.msg or "?"))
  else
    self:resolve("error:" .. id)
  end
end

function Fleet:onTurtleHeartbeat(from, b, now)
  if type(self.cfg.turtles) == "table" and not contains(self.cfg.turtles, from) then
    self:deny(from, "heartbeat", "not in turtles allowlist")
    return nil
  end
  local t = self.turtles[from]
  if not t then
    t = { id = from, firstSeen = now }
    self.turtles[from] = t
    if self.log then self.log:info("new turtle #%d in %s", from, tostring(b.dim)) end
  end
  t.label = str(b.label, 24)
  t.dim = b.dim or t.dim
  local x, y, z = int(b.x), int(b.y), int(b.z)
  if x and y and z then
    t.x, t.y, t.z, t.posAt = x, y, z, now
  end
  t.h = int(b.h)
  if t.h and (t.h < 0 or t.h > 3) then t.h = nil end
  t.fix = str(b.fix, 8) or "none"
  t.fixAge = int(b.fixAge)
  t.gpsErr = str(b.gpsErr, 60)
  t.fuel, t.fuelMax, t.reserve = int(b.fuel), int(b.fuelMax), int(b.reserve)
  if type(b.inv) == "table" then t.invUsed, t.invTotal = int(b.inv[1]), int(b.inv[2]) end
  t.status = str(b.status, 16) or "?"
  if type(b.job) == "table" then
    t.job = str(b.job.name, 24)
    t.progress = num(b.job.progress)
  else
    t.job, t.progress = str(b.job, 24), nil
  end
  t.msg = str(b.msg, 80)
  t.ver = str(b.ver, 12)
  t.up = int(b.up)
  t.lastSeen = now
  if t.link == "lost" then self:resolve("lost:" .. from, "back online") end
  t.link = "ok"
  self:evaluate(t)
  self.dirty = true
  return { type = P.HB_ACK, ver = self.ver }
end

function Fleet:onGpsHeartbeat(from, b, now)
  local g = self.gps[from]
  if not g then
    g = { id = from }
    self.gps[from] = g
  end
  g.dim = b.dim
  g.x, g.y, g.z = int(b.x), int(b.y), int(b.z)
  g.label = str(b.label, 24)
  g.served = int(b.served)
  g.verdict = str(b.verdict, 60)
  g.ver = str(b.ver, 12)
  g.lastSeen = now
  if g.link == "lost" then self:resolve("gps:" .. from, "back online") end
  g.link = "ok"
  self.dirty = true
  return { type = P.HB_ACK, ver = self.ver }
end

--- Updates stale/lost status. Call about once a second.
function Fleet:tick(now)
  local stale, lost = (self.cfg.staleAfter or 12) * 1000, (self.cfg.lostAfter or 45) * 1000
  local grace = now - self.bootAt < lost
  for id, t in pairs(self.turtles) do
    local age = now - (t.lastSeen or 0)
    local link = age > lost and "lost" or (age > stale and "stale" or "ok")
    if link == "lost" and t.link ~= "lost" and grace then link = "stale" end
    if link ~= t.link then
      t.link = link
      self.dirty = true
      if link == "lost" then
        self:raise("lost:" .. id, "lost", 3, t, ("%s LOST in %s: silent %s, last at %s"):format(
          name(t), P.dimLabel(t.dim), U.age(age), t.x and U.fmtPos(t) or "unknown position"))
      end
    end
  end
  for id, g in pairs(self.gps) do
    local age = now - (g.lastSeen or 0)
    local link = age > GPS_LOST_AFTER * 1000 and "lost" or "ok"
    if link == "lost" and g.link ~= "lost" and now - self.bootAt < GPS_LOST_AFTER * 1000 then link = "ok" end
    if link ~= g.link then
      g.link = link
      self.dirty = true
      if link == "lost" then
        self:raise("gps:" .. id, "gps", 2, g, ("GPS host #%d (%s) offline: turtles there may lose GPS"):format(
          id, P.dimLabel(g.dim)))
      end
    end
  end
end

-- Requests ---------------------------------------------------------------------------

--- Handles one verified message. Returns a reply body or nil.
function Fleet:handle(from, body, now)
  local ty = body.type
  if ty == P.HB then
    if body.role == "gpshost" then return self:onGpsHeartbeat(from, body, now) end
    if body.role == "pocket" then return { type = P.HB_ACK, ver = self.ver } end
    return self:onTurtleHeartbeat(from, body, now)
  elseif ty == P.ACTION or ty == P.VIEW_REQ then
    if not self:isCommander(from) then
      self:deny(from, ty, "not in commanders allowlist")
      return nil
    end
    if ty == P.ACTION then
      local ok, msg = self:action(body)
      return { type = P.ACTION_R, ok = ok, msg = msg, req = body.req }
    end
    return self:view(P.normDim(body.view) or body.dim, now, true)
  end
  return nil
end

--- UI actions (local monitor, or allowlisted pockets). Returns ok, message.
function Fleet:action(a)
  if a.op == "forget" then
    local t = self.turtles[a.id]
    if not t then return false, "no such turtle" end
    self.turtles[a.id] = nil
    for _, k in ipairs({ "lost", "fuel", "full", "stuck", "error" }) do self:resolve(k .. ":" .. a.id, "forgotten") end
    self.dirty = true
    return true, "forgot " .. name(t)
  elseif a.op == "forgetGps" then
    if not self.gps[a.id] then return false, "no such GPS host" end
    self.gps[a.id] = nil
    self:resolve("gps:" .. a.id, "forgotten")
    self.dirty = true
    return true, "forgot GPS host #" .. a.id
  elseif a.op == "ack" then
    for _, al in ipairs(self.alerts) do
      if al.id == a.id then
        al.acked = true
        self.dirty = true
        return true, "acknowledged"
      end
    end
    return false, "no such alert"
  elseif a.op == "ackAll" then
    for _, al in ipairs(self.alerts) do if al.active then al.acked = true end end
    self.dirty = true
    return true, "all acknowledged"
  end
  return false, "unknown action " .. tostring(a.op)
end

local VIEW_FIELDS = {
  "id", "label", "dim", "x", "y", "z", "h", "fix", "fixAge", "gpsErr", "fuel", "fuelMax", "invUsed",
  "invTotal", "status", "job", "progress", "msg", "ver", "link", "lastSeen", "posAt",
}

--- Everything a map client needs for one dimension.
function Fleet:view(dim, now, forWire)
  dim = dim or "overworld"
  local v = {
    type = P.VIEW, now = now, view = dim, ver = self.ver,
    turtles = {}, gps = {}, waypoints = {}, players = {}, dims = {}, alerts = {},
  }
  local function dimInfo(d)
    if not v.dims[d] then v.dims[d] = { turtles = 0, lost = 0, gps = 0, gpsDown = 0 } end
    return v.dims[d]
  end
  for _, d in ipairs(P.DIM_ORDER) do dimInfo(d) end
  local flags = {}
  for _, a in ipairs(self.alerts) do
    if a.active and a.tid then flags[a.kind .. ":" .. a.tid] = true end
  end
  for _, id in ipairs(U.sortedKeys(self.turtles)) do
    local t = self.turtles[id]
    local info = dimInfo(t.dim or "unknown")
    info.turtles = info.turtles + 1
    if t.link == "lost" then info.lost = info.lost + 1 end
    if (t.dim or "unknown") == dim then
      local c = {}
      for _, f in ipairs(VIEW_FIELDS) do c[f] = t[f] end
      c.age = now - (t.lastSeen or 0)
      c.lowFuel = flags["lowfuel:" .. id]
      c.full = flags["full:" .. id]
      c.old = t.ver ~= nil and self.ver ~= "none" and t.ver ~= self.ver
      v.turtles[#v.turtles + 1] = c
    end
  end
  for _, id in ipairs(U.sortedKeys(self.gps)) do
    local g = self.gps[id]
    local info = dimInfo(g.dim or "unknown")
    info.gps = info.gps + 1
    if g.link == "lost" then info.gpsDown = info.gpsDown + 1 end
    if g.dim == dim then
      v.gps[#v.gps + 1] = { id = id, x = g.x, y = g.y, z = g.z, link = g.link, verdict = g.verdict }
    end
  end
  local garage = self.cfg.garages and self.cfg.garages[dim]
  if type(garage) == "table" and garage.x then
    v.waypoints[#v.waypoints + 1] = { name = "Garage", x = garage.x, y = garage.y, z = garage.z, kind = "garage" }
  end
  for _, wp in ipairs(self.waypoints[dim] or {}) do v.waypoints[#v.waypoints + 1] = wp end
  for _, a in ipairs(self:activeAlerts()) do
    if #v.alerts >= 20 then break end
    v.alerts[#v.alerts + 1] = {
      id = a.id, kind = a.kind, sev = a.sev, text = a.text, dim = a.dim, tid = a.tid, t = a.t, acked = a.acked,
    }
  end
  if not forWire then v.denied = self.denied end
  return v
end

return Fleet
