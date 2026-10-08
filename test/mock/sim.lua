-- Discrete-event simulation of several CC:Tweaked computers sharing a world and an
-- ender-modem network. Time is simulated: nothing waits in real time.

local FS = require("mock.fs")
local Screen = require("mock.screen")
local World = require("mock.world")
local Periph = require("mock.periph")
local makeEnv = require("mock.env")
local makeNatives = require("mock.natives")

local Sim = {}
Sim.__index = Sim

local TICK = 0.05
local INSTRUCTION_LIMIT = 2e8 -- stand-in for "Too long without yielding"

local hostFiles -- cache of src/fleet

local function listHost(dir)
  local out = {}
  local p = io.popen('cd "' .. dir .. '" && find . -type f')
  for line in p:lines() do out[#out + 1] = line:sub(3) end
  p:close()
  table.sort(out)
  return out
end

local function readHost(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local r = {}
  for k, x in pairs(v) do r[deepcopy(k)] = deepcopy(x) end
  return r
end

function Sim.new(opts)
  opts = opts or {}
  local self = setmetatable({
    t = 0,
    epoch0 = 1760000000000,
    pending = {}, seq = 0,
    computers = {},
    world = World.new(),
    players = {},
    chat = {}, sounds = {}, echoes = {}, errors = {},
    srcRoot = opts.srcRoot or "src/fleet",
    verbose = opts.verbose,
    ser = nil,
  }, Sim)
  self.ser = self:loadSer()
  local romDir = opts.rom
  if romDir == nil then romDir = os.getenv("CC_ROM") end
  if romDir and romDir ~= "" then self:loadRom(romDir) end
  return self
end

local romCache = {}

--- Loads bios.lua and rom/ from a CC:Tweaked checkout (data/computercraft/lua).
function Sim:loadRom(dir)
  if not romCache[dir] then
    local rom = { files = {}, dirs = { rom = true } }
    for _, rel in ipairs(listHost(dir .. "/rom")) do
      local path = "rom/" .. rel
      rom.files[path] = readHost(dir .. "/rom/" .. rel)
      local d = path:match("^(.*)/[^/]*$")
      while d and d ~= "" and not rom.dirs[d] do
        rom.dirs[d] = true
        d = d:match("^(.*)/[^/]*$")
      end
    end
    romCache[dir] = { rom = rom, bios = readHost(dir .. "/bios.lua") }
  end
  self.rom = romCache[dir]
end

function Sim:loadSer()
  local fn = assert(loadfile(self.srcRoot .. "/lib/ser.lua"))
  return fn()
end

-- Scheduling ---------------------------------------------------------------------

function Sim:schedule(at, fn)
  self.seq = self.seq + 1
  local item = { t = at, seq = self.seq, fn = fn }
  local q = self.pending
  local lo, hi = 1, #q + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local m = q[mid]
    if m.t < at or (m.t == at and m.seq < item.seq) then lo = mid + 1 else hi = mid end
  end
  table.insert(q, lo, item)
end

local function ceilTick(t) return math.ceil(t / TICK - 1e-9) * TICK end

local QUEUE_LIMIT = 256 -- CC:Tweaked ComputerExecutor drops events beyond this

function Sim:queue(c, ev)
  if not c.running then return end
  ev.n = ev.n or #ev
  if #c.events >= QUEUE_LIMIT then
    c.dropped = (c.dropped or 0) + 1
    return
  end
  c.events[#c.events + 1] = ev
end

function Sim:startTimer(c, secs)
  c.timerSeq = c.timerSeq + 1
  local id = c.timerSeq
  local gen = c.gen
  local at = ceilTick(self.t + math.max(secs or 0, TICK))
  self:schedule(at, function()
    if c.gen == gen and not c.cancelled[id] then self:queue(c, table.pack("timer", id)) end
    c.cancelled[id] = nil
  end)
  return id
end

function Sim:cancelTimer(c, id) c.cancelled[id] = true end

function Sim:turtleResponse(c, duration, ok, err)
  c.turtleSeq = c.turtleSeq + 1
  local id = c.turtleSeq
  local gen = c.gen
  self:schedule(ceilTick(self.t + duration), function()
    if c.gen == gen then self:queue(c, table.pack("turtle_response", id, ok, err)) end
  end)
  return id
end

--- Runs a peripheral method the way CC:Tweaked runs @LuaFunction(mainThread = true):
--- the caller yields until a "task_complete" event on the next tick, so other events
--- reaching that coroutine in the meantime are lost (as in game).
function Sim:mainThread(c, fn, ...)
  local results = table.pack(pcall(fn, ...))
  c.taskSeq = (c.taskSeq or 0) + 1
  local id, gen = c.taskSeq, c.gen
  self:schedule(ceilTick(self.t + TICK), function()
    if c.gen == gen then self:queue(c, table.pack("task_complete", id, table.unpack(results, 1, results.n))) end
  end)
  while true do
    local ev = table.pack(coroutine.yield("task_complete"))
    if ev[1] == "task_complete" and ev[2] == id then
      if not ev[3] then error(ev[4], 0) end
      return table.unpack(ev, 4, ev.n)
    end
  end
end

-- Computers --------------------------------------------------------------------------

--- spec: id, kind ("computer"|"turtle"|"pocket"), label, dim, pos {x,y,z}, heading,
---   peripherals { side = { "modem", ender = true } | { "monitor", w, h } | { "playerDetector" } ... },
---   files { path = content }, install (copy src/fleet into /fleet), owner (pocket player),
---   fuel, inv { [slot] = { name, count } }, equip { left = item, right = item }, boot (default true)
function Sim:add(spec)
  local c = {
    id = spec.id, kind = spec.kind or "computer", label = spec.label,
    dim = spec.dim or "overworld", heading = spec.heading or 0, owner = spec.owner,
    fs = FS.new({ capacity = spec.capacity, rom = self.rom and self.rom.rom }),
    events = {}, cancelled = {}, timerSeq = 0, turtleSeq = 0, gen = 0,
    peripherals = {}, running = false, maxBurst = 0, instructions = 0,
    output = {},
  }
  if spec.pos then c.pos = { x = spec.pos[1] or spec.pos.x, y = spec.pos[2] or spec.pos.y, z = spec.pos[3] or spec.pos.z } end
  assert(not self.computers[c.id], "duplicate computer id " .. tostring(c.id))
  if c.kind == "pocket" then
    c.screen = Screen.new(26, 20, true)
  elseif c.kind == "turtle" then
    c.screen = Screen.new(39, 13, true)
    c.turtle = {
      fuel = spec.fuel or 1000, fuelLimit = spec.fuelLimit or 100000, selected = 1,
      slots = deepcopy(spec.inv or {}), equipped = deepcopy(spec.equip or {}),
    }
    self.world:setOccupant(c.dim, c.pos.x, c.pos.y, c.pos.z, c)
  else
    c.screen = Screen.new(51, 19, true)
  end
  for side, p in pairs(spec.peripherals or {}) do self:attach(c, side, p) end
  if c.kind == "turtle" then
    for _, side in ipairs({ "left", "right" }) do self:onEquipChanged(c, side, true) end
  end
  if spec.install ~= false then self:install(c) end
  for path, content in pairs(spec.files or {}) do c.fs:writeFile(path, content) end
  self.computers[c.id] = c
  if spec.boot ~= false then self:boot(c) end
  return c
end

function Sim:attach(c, side, p)
  local kind = p[1]
  local obj
  if kind == "modem" then obj = Periph.modem(self, c, side, p.ender)
  elseif kind == "monitor" then obj = Periph.monitor(self, c, side, p.w or p[2], p.h or p[3])
  elseif kind == "playerDetector" then obj = Periph.playerDetector(self, c, side)
  elseif kind == "chatBox" then obj = Periph.chatBox(self, c, side)
  elseif kind == "speaker" then obj = Periph.speaker(self, c, side)
  else error("unknown peripheral " .. tostring(kind)) end
  c.peripherals[side] = obj
  return obj
end

--- Same manifest format as lib/update.lua and tools/build.lua write.
function Sim:manifestFor(files)
  local sha2 = dofile(self.srcRoot .. "/lib/sha2.lua")
  local hashes, lines = {}, {}
  for rel, content in pairs(files) do
    hashes[rel] = sha2.sha256Hex(content)
    lines[#lines + 1] = rel .. "=" .. hashes[rel]
  end
  table.sort(lines)
  return { files = hashes, ver = sha2.sha256Hex(table.concat(lines, "\n")):sub(1, 8) }
end

function Sim:install(c)
  if not hostFiles then
    hostFiles = {}
    for _, rel in ipairs(listHost(self.srcRoot)) do hostFiles[rel] = readHost(self.srcRoot .. "/" .. rel) end
    hostFiles.__manifest = self.ser.serialize(self:manifestFor(hostFiles))
  end
  for rel, content in pairs(hostFiles) do
    if rel ~= "__manifest" then c.fs:writeFile("/fleet/" .. rel, content) end
  end
  c.fs:writeFile("/fleet/manifest", hostFiles.__manifest)
  c.fs:writeFile("/startup.lua", 'shell.run("/fleet/boot.lua")\n')
end

function Sim:boot(c)
  c.gen = c.gen + 1
  c.events, c.cancelled = {}, {}
  c.running = true
  c.bootTime = self.t
  c.filter = nil
  c.crashed = nil
  c.screen:api().clear()
  c.screen:api().setCursorPos(1, 1)
  for _, p in pairs(c.peripherals) do if p.type == "modem" then p.channels = {} end end
  c.hook = function()
    c.icount = c.icount + 1000
    if c.icount > INSTRUCTION_LIMIT then error("Too long without yielding", 0) end
  end
  if self.rom then
    -- real CraftOS: bios.lua runs the shell (which runs /startup.lua) and rednet.run
    c.env = makeNatives(self, c)
    local bios = assert(load(self.rom.bios, "@bios.lua", "t", c.env))
    c.co = coroutine.create(bios)
  else
    c.env = makeEnv(self, c)
    local env = c.env
    c.co = coroutine.create(function()
      if c.fs:readFile("/startup.lua") then
        env.shell.run("/startup.lua")
      end
    end)
  end
  debug.sethook(c.co, c.hook, "", 1000)
  self:resume(c, { n = 0 })
  self:feedInput(c)
end

function Sim:resume(c, ev)
  c.icount = 0
  local ok, res = coroutine.resume(c.co, table.unpack(ev, 1, ev.n))
  if c.icount > c.maxBurst then c.maxBurst = c.icount end
  c.instructions = c.instructions + c.icount
  if not ok then
    c.running = false
    c.crashed = res
    self.errors[#self.errors + 1] = { id = c.id, err = res }
    if self.verbose then print(("[sim] #%d crashed: %s"):format(c.id, tostring(res))) end
  elseif coroutine.status(c.co) == "dead" then
    c.running = false
    c.exited = true
  else
    c.filter = res
  end
end

function Sim:deliver(c, ev)
  if c.filter ~= nil and ev[1] ~= c.filter and ev[1] ~= "terminate" then return end
  self:resume(c, ev)
end

function Sim:requestReboot(c)
  local gen = c.gen
  self:schedule(self.t + TICK, function() if c.gen == gen then self:boot(c) end end)
end

function Sim:requestShutdown(c)
  local gen = c.gen
  self:schedule(self.t + TICK, function()
    if c.gen == gen then c.running = false; c.gen = c.gen + 1 end
  end)
end

--- Simulates the chunk unloading: the computer stops and hears nothing.
function Sim:unload(c)
  c.running = false
  c.gen = c.gen + 1
  c.unloaded = true
end

--- Chunk loads again: CC turns the computer back on, which runs startup.
function Sim:load(c)
  c.unloaded = false
  self:boot(c)
end

function Sim:programError(c, err)
  self.errors[#self.errors + 1] = { id = c.id, err = err }
  if self.verbose then print(("[sim] #%d program error: %s"):format(c.id, tostring(err))) end
end

function Sim:echo(c, line)
  c.output[#c.output + 1] = line
  if #c.output > 200 then table.remove(c.output, 1) end
  if self.verbose == "all" then print(("[%6.2f #%d] %s"):format(self.t, c.id, line)) end
end

--- Runs the simulation for `secs` simulated seconds.
function Sim:run(secs)
  local stop = self.t + secs
  local storm = 0
  while true do
    local any = false
    local ids = {}
    for id, c in pairs(self.computers) do
      if c.running and #c.events > 0 then ids[#ids + 1] = id end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local c = self.computers[id]
      if c.running and #c.events > 0 then
        any = true
        self:deliver(c, table.remove(c.events, 1))
      end
    end
    if any then
      storm = storm + 1
      if storm > 200000 then error("event storm at t=" .. self.t) end
    else
      storm = 0
      local nxt = self.pending[1]
      if not nxt or nxt.t > stop then
        self.t = stop
        return
      end
      table.remove(self.pending, 1)
      self.t = nxt.t
      nxt.fn()
    end
  end
end

--- Runs until predicate() is true or `limit` seconds pass. Returns true if it became true.
function Sim:runUntil(pred, limit, step)
  local stop = self.t + (limit or 60)
  step = step or 0.5
  while self.t < stop do
    if pred() then return true end
    self:run(step)
  end
  return pred()
end

-- Network ----------------------------------------------------------------------------------

function Sim:modemPos(c)
  if c.kind == "pocket" then
    local pl = self.players[c.owner]
    if not pl then return nil end
    return pl.x, pl.y + 1.62, pl.z, pl.dim
  end
  return c.pos.x + 0.5, c.pos.y + 0.5, c.pos.z + 0.5, c.dim
end

function Sim:transmit(from, fromModem, ch, reply, msg)
  local fx, fy, fz, fdim = self:modemPos(from)
  if not fx then return end
  local ids = {}
  for id in pairs(self.computers) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local c = self.computers[id]
    if c ~= from and c.running then
      local delivered = false
      for side, p in pairs(c.peripherals) do
        if not delivered and p.type == "modem" and p.channels[ch] then
          local x, y, z, dim = self:modemPos(c)
          local ok, dist = false, nil
          if x and dim == fdim then
            dist = math.sqrt((x - fx) ^ 2 + (y - fy) ^ 2 + (z - fz) ^ 2)
            ok = fromModem.ender or p.ender or dist <= 64
          elseif x then
            ok = fromModem.ender or p.ender
          end
          if ok then
            delivered = true
            local copy = deepcopy(msg)
            self:queue(c, table.pack("modem_message", side, ch, reply, copy, dist))
            -- what CraftOS' rednet daemon would turn this into (real ROM mode runs the daemon)
            if not self.rom and type(copy) == "table" and copy.nMessageID and (ch == c.id % 65500 or ch == 65535)
                and p.channels[c.id % 65500] and p.channels[65535]
                and (copy.nRecipient == c.id or copy.nRecipient == 65535) then
              self:queue(c, table.pack("rednet_message", copy.nSender or reply, copy.message, copy.sProtocol))
            end
          end
        end
      end
    end
  end
end

-- Turtle hooks -------------------------------------------------------------------------------

function Sim:onTurtleMoved(c) end
function Sim:onInspect(c, x, y, z, b) end
function Sim:onDrop(c, dir, name, n) end

function Sim:onEquipChanged(c, side, initial)
  local item = c.turtle.equipped[side]
  local u = item and World.UPGRADES[item]
  local had = c.peripherals[side]
  if u and u.kind == "modem" then
    if not had then
      self:attach(c, side, { "modem", ender = u.ender })
      if not initial then self:queue(c, table.pack("peripheral", side)) end
    end
  elseif had then
    c.peripherals[side] = nil
    if not initial then self:queue(c, table.pack("peripheral_detach", side)) end
  end
end

-- Input helpers ---------------------------------------------------------------------------------

function Sim:touch(c, side, x, y) self:queue(c, table.pack("monitor_touch", side, x, y)) end
function Sim:click(c, x, y, button) self:queue(c, table.pack("mouse_click", button or 1, x, y)) end
function Sim:release(c, x, y, button) self:queue(c, table.pack("mouse_up", button or 1, x, y)) end
function Sim:drag(c, x, y, button) self:queue(c, table.pack("mouse_drag", button or 1, x, y)) end
function Sim:key(c, code) self:queue(c, table.pack("key", code, false)) end
function Sim:char(c, ch) self:queue(c, table.pack("char", ch)) end
--- Scripted keyboard input for read(). Light mode feeds read() directly; real ROM mode
--- queues char/key events that CraftOS' read() consumes.
function Sim:typeLines(c, lines)
  if not self.rom then
    c.inputs = lines
    return
  end
  c.pendingInput = lines
end

function Sim:feedInput(c)
  local lines = c.pendingInput
  if not lines then return end
  c.pendingInput = nil
  for _, line in ipairs(lines) do
    for i = 1, #line do self:queue(c, table.pack("char", line:sub(i, i))) end
    self:queue(c, table.pack("key", 257, false))
    self:queue(c, table.pack("key_up", 257))
  end
end
function Sim:terminate(c) self:queue(c, table.pack("terminate")) end

function Sim:player(name, x, y, z, dim)
  self.players[name] = { x = x, y = y, z = z, dim = dim or "overworld", online = true }
  return self.players[name]
end

function Sim:monitor(c, side)
  for s, p in pairs(c.peripherals) do
    if p.type == "monitor" and (side == nil or s == side) then return p.screen end
  end
end

return Sim
