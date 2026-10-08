-- Builds the CC:Tweaked global environment for one mock computer.
-- Event semantics follow CC: os.pullEventRaw(filter) == coroutine.yield(filter), the
-- top-level coroutine only sees events matching its filter (others are dropped), and
-- parallel/sleep are ports of the CraftOS implementations.

local makeTurtle = require("mock.turtle")

local COLORS = {
  white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32, pink = 64, gray = 128,
  lightGray = 256, cyan = 512, purple = 1024, blue = 2048, brown = 4096, green = 8192, red = 16384,
  black = 32768,
}

local KEYS = {
  space = 32, apostrophe = 39, comma = 44, minus = 45, period = 46, slash = 47,
  zero = 48, one = 49, two = 50, three = 51, four = 52, five = 53, six = 54, seven = 55, eight = 56,
  nine = 57, semicolon = 59, equals = 61, leftBracket = 91, backslash = 92, rightBracket = 93,
  enter = 257, tab = 258, backspace = 259, delete = 261, right = 262, left = 263, down = 264, up = 265,
  pageUp = 266, pageDown = 267, home = 268, ["end"] = 269, f1 = 290, leftShift = 340, leftCtrl = 341,
}
for i = 0, 25 do KEYS[string.char(97 + i)] = 65 + i end

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local r = {}
  for k, x in pairs(v) do r[deepcopy(k)] = deepcopy(x) end
  return r
end

return function(sim, c)
  local G = {}
  for _, k in ipairs({ "assert", "error", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget",
    "rawlen", "rawset", "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type", "xpcall" }) do
    G[k] = _G[k]
  end
  G.string, G.table, G.math, G.bit32 = string, table, math, bit32
  -- every coroutine a computer creates is metered by the "too long without yielding" hook
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
  G.unpack = table.unpack
  G.debug = { traceback = debug.traceback, getinfo = debug.getinfo }
  G._VERSION = _VERSION
  G._HOST = "ComputerCraft 1.113.1 (TurtleGPS mock harness)"
  G.load = function(chunk, name, mode, env) return load(chunk, name, mode, env or G) end
  G.loadstring = function(s, name) return load(s, name, "t", G) end
  G._G = G

  -- os ----------------------------------------------------------------------
  local os_ = {}
  function os_.getComputerID() return c.id end
  os_.computerID = os_.getComputerID
  function os_.getComputerLabel() return c.label end
  os_.computerLabel = os_.getComputerLabel
  function os_.setComputerLabel(l) c.label = l end
  function os_.clock() return sim.t - c.bootTime end
  function os_.epoch(kind)
    if kind == "utc" or kind == "local" then return math.floor(sim.epoch0 + sim.t * 1000) end
    return math.floor((6000 + sim.t * 20) * 3600)
  end
  function os_.time() return ((6 + sim.t / 50) % 24) end
  function os_.day() return 1 + math.floor((6 + sim.t / 50) / 24) end
  function os_.startTimer(secs) return sim:startTimer(c, secs) end
  function os_.cancelTimer(id) sim:cancelTimer(c, id) end
  function os_.queueEvent(...) sim:queue(c, table.pack(...)) end
  function os_.pullEventRaw(filter) return coroutine.yield(filter) end
  function os_.pullEvent(filter)
    local ev = table.pack(coroutine.yield(filter))
    if ev[1] == "terminate" then error("Terminated", 0) end
    return table.unpack(ev, 1, ev.n)
  end
  function os_.reboot()
    sim:requestReboot(c)
    while true do coroutine.yield("__never") end
  end
  function os_.shutdown()
    sim:requestShutdown(c)
    while true do coroutine.yield("__never") end
  end
  function os_.version() return "CraftOS 1.9" end
  G.os = os_

  function G.sleep(t)
    local timer = os_.startTimer(t or 0)
    repeat
      local _, param = os_.pullEvent("timer")
    until param == timer
  end

  -- fs ----------------------------------------------------------------------
  local fs_ = c.fs:api()
  G.fs = fs_

  -- term --------------------------------------------------------------------
  local native = c.screen:api()
  local current = native
  local term = {}
  function term.redirect(t) local old = current; current = t; return old end
  function term.current() return current end
  function term.native() return native end
  setmetatable(term, { __index = function(_, k) return current[k] end })
  G.term = term

  function G.write(s)
    s = tostring(s)
    local w, h = current.getSize()
    local lines = 0
    local function newline()
      local _, y = current.getCursorPos()
      if y + 1 > h then current.scroll(1); current.setCursorPos(1, h)
      else current.setCursorPos(1, y + 1) end
      lines = lines + 1
    end
    local first = true
    for line in (s .. "\n"):gmatch("(.-)\n") do
      if not first then newline() end
      first = false
      while #line > 0 do
        local x = current.getCursorPos()
        local room = w - x + 1
        if room <= 0 then newline(); room = w end
        current.write(line:sub(1, room))
        line = line:sub(room + 1)
      end
    end
    return lines
  end
  function G.print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local n = G.write(table.concat(parts, "\t") .. "\n")
    sim:echo(c, table.concat(parts, "\t"))
    return n
  end
  function G.printError(...)
    local old = current.getTextColor()
    if current.isColor() then current.setTextColor(COLORS.red) end
    G.print(...)
    current.setTextColor(old)
  end
  -- read() takes scripted lines from sim:typeLines(c, {...}); echoes them like CC does
  function G.read()
    local line = table.remove(c.inputs or {}, 1) or ""
    G.write(line .. "\n")
    sim:echo(c, "> " .. line)
    return line
  end

  -- colors / keys -------------------------------------------------------------
  local colors = {}
  for k, v in pairs(COLORS) do colors[k] = v end
  colors.gray, colors.grey = COLORS.gray, COLORS.gray
  colors.lightGray, colors.lightGrey = COLORS.lightGray, COLORS.lightGray
  function colors.combine(...)
    local r = 0
    for i = 1, select("#", ...) do r = bit32.bor(r, select(i, ...)) end
    return r
  end
  function colors.subtract(a, ...) return bit32.band(a, bit32.bnot(colors.combine(...))) end
  function colors.test(a, b) return bit32.band(a, b) == b end
  function colors.toBlit(col)
    local n = math.floor(math.log(col) / math.log(2) + 0.5)
    return ("0123456789abcdef"):sub(n + 1, n + 1)
  end
  G.colors, G.colours = colors, colors
  local keys = {}
  for k, v in pairs(KEYS) do keys[k] = v end
  function keys.getName(code)
    for k, v in pairs(KEYS) do if v == code then return k end end
  end
  G.keys = keys

  -- peripheral ----------------------------------------------------------------
  local per = {}
  local names = {}
  local function get(side) return c.peripherals[side] end
  function per.getNames()
    local out = {}
    for side in pairs(c.peripherals) do out[#out + 1] = side end
    table.sort(out)
    return out
  end
  function per.isPresent(side) return get(side) ~= nil end
  function per.getType(p)
    if type(p) == "table" then p = names[p] end
    local x = get(p)
    return x and x.type or nil
  end
  function per.hasType(p, t) return per.getType(p) == t end
  function per.getMethods(side)
    local x = get(side)
    if not x then return nil end
    local out = {}
    for k in pairs(x.methods) do out[#out + 1] = k end
    return out
  end
  function per.call(side, method, ...)
    local x = get(side)
    if not x then error("No peripheral attached", 2) end
    local f = x.methods[method]
    if not f then error("No such method " .. tostring(method), 2) end
    return f(...)
  end
  function per.wrap(side)
    local x = get(side)
    if not x then return nil end
    names[x.methods] = side
    return x.methods
  end
  function per.getName(w) return names[w] end
  function per.find(ptype, filter)
    local out = {}
    for _, side in ipairs(per.getNames()) do
      local x = get(side)
      if x.type == ptype then
        local w = per.wrap(side)
        if not filter or filter(side, w) then out[#out + 1] = w end
      end
    end
    return table.unpack(out)
  end
  G.peripheral = per

  -- rednet (wire format compatible with CraftOS rednet) ---------------------------
  local rednet = { CHANNEL_BROADCAST = 65535, CHANNEL_REPEAT = 65533, MAX_ID_CHANNELS = 65500 }
  local function idChannel(id) return (id or c.id) % rednet.MAX_ID_CHANNELS end
  local function modemSide(side)
    local x = get(side)
    if not x or x.type ~= "modem" then error("No such modem: " .. tostring(side), 3) end
    return x
  end
  function rednet.open(side)
    local m = modemSide(side)
    m.methods.open(idChannel())
    m.methods.open(rednet.CHANNEL_BROADCAST)
  end
  function rednet.close(side)
    if side then
      local m = modemSide(side)
      m.methods.close(idChannel())
      m.methods.close(rednet.CHANNEL_BROADCAST)
    else
      for _, s in ipairs(per.getNames()) do
        if rednet.isOpen(s) then rednet.close(s) end
      end
    end
  end
  function rednet.isOpen(side)
    if side then
      local x = get(side)
      return x ~= nil and x.type == "modem" and x.channels[idChannel()] == true
        and x.channels[rednet.CHANNEL_BROADCAST] == true
    end
    for _, s in ipairs(per.getNames()) do if rednet.isOpen(s) then return true end end
    return false
  end
  function rednet.send(to, msg, proto)
    local wrapper = {
      nMessageID = math.random(1, 2147483647), nRecipient = to, nSender = c.id,
      message = msg, sProtocol = proto,
    }
    if to == c.id then
      sim:queue(c, table.pack("rednet_message", c.id, deepcopy(msg), proto))
      return true
    end
    local ch = to == rednet.CHANNEL_BROADCAST and to or idChannel(to)
    local sent = false
    for _, s in ipairs(per.getNames()) do
      if rednet.isOpen(s) then
        get(s).methods.transmit(ch, idChannel(), wrapper)
        sent = true
      end
    end
    return sent
  end
  function rednet.broadcast(msg, proto) rednet.send(rednet.CHANNEL_BROADCAST, msg, proto) end
  function rednet.receive(proto, timeout)
    local timer = timeout and os_.startTimer(timeout)
    while true do
      local ev, a, b, p = os_.pullEvent()
      if ev == "rednet_message" and (proto == nil or p == proto) then return a, b, p end
      if ev == "timer" and a == timer then return nil end
    end
  end
  function rednet.host() end
  function rednet.unhost() end
  function rednet.lookup() return nil end
  function rednet.run() while true do coroutine.yield() end end
  G.rednet = rednet

  G.gps = { CHANNEL_GPS = 65534 }

  -- parallel (port of CraftOS parallel.lua) ---------------------------------------
  local function create(...)
    local fns = table.pack(...)
    local cos = {}
    for i = 1, fns.n do
      if type(fns[i]) ~= "function" then error("bad argument #" .. i .. " (function expected)", 3) end
      cos[i] = co.create(fns[i])
    end
    return cos
  end
  local function runUntilLimit(routines, limit)
    local count = #routines
    if count < 1 then return 0 end
    local living = count
    local filters = {}
    local eventData = { n = 0 }
    while true do
      for n = 1, count do
        local r = routines[n]
        if r then
          if filters[r] == nil or filters[r] == eventData[1] or eventData[1] == "terminate" then
            local ok, param = coroutine.resume(r, table.unpack(eventData, 1, eventData.n))
            if not ok then
              error(param, 0)
            else
              filters[r] = param
            end
            if coroutine.status(r) == "dead" then
              routines[n] = nil
              living = living - 1
              if living <= limit then return n end
            end
          end
        end
      end
      for n = 1, count do
        local r = routines[n]
        if r and coroutine.status(r) == "dead" then
          routines[n] = nil
          living = living - 1
          if living <= limit then return n end
        end
      end
      eventData = table.pack(os_.pullEventRaw())
    end
  end
  G.parallel = {
    waitForAny = function(...) return runUntilLimit(create(...), #{ ... } - 1) end,
    waitForAll = function(...) return runUntilLimit(create(...), 0) end,
  }

  -- textutils (minimal) ---------------------------------------------------------------
  G.textutils = {
    urlEncode = function(s)
      return (tostring(s):gsub("\n", "\r\n"):gsub("[^%w%-%._~ ]", function(ch)
        return ("%%%02X"):format(ch:byte())
      end):gsub(" ", "+"))
    end,
    serialize = function(t) return sim.ser.serialize(t) end,
    unserialize = function(s) return sim.ser.unserialize(s) end,
    formatTime = function(t) return string.format("%d:%02d", math.floor(t), math.floor((t % 1) * 60)) end,
  }

  -- loadfile / dofile / require / shell ----------------------------------------------
  function G.loadfile(path, mode, env)
    local src = c.fs:readFile(path)
    if not src then return nil, "File not found" end
    return load(src, "@/" .. fs_.combine(path), mode or "t", env or G)
  end
  function G.dofile(path)
    local fn, err = G.loadfile(path)
    if not fn then error(err, 2) end
    return fn()
  end

  local function makeRequire(env, dir)
    local package = {
      loaded = { _G = G, string = string, table = table, math = math, bit32 = bit32, coroutine = coroutine },
      path = "?;?.lua;?/init.lua;/rom/modules/main/?;/rom/modules/main/?.lua",
      preload = {},
      config = "/\n;\n?\n!\n-",
    }
    local function require(name)
      if package.loaded[name] ~= nil then return package.loaded[name] end
      local fname = name:gsub("%.", "/")
      local tried = {}
      for pattern in package.path:gmatch("[^;]+") do
        local path = pattern:gsub("%?", fname)
        if path:sub(1, 1) ~= "/" then path = fs_.combine(dir, path) end
        if fs_.exists(path) and not fs_.isDir(path) then
          local fn, err = load(c.fs:readFile(path), "@/" .. fs_.combine(path), "t", env)
          if not fn then error(err, 0) end
          local result = fn(name, path)
          if result == nil then result = true end
          package.loaded[name] = result
          return result
        end
        tried[#tried + 1] = "  no file '" .. path .. "'"
      end
      error("module '" .. name .. "' not found:\n" .. table.concat(tried, "\n"), 2)
    end
    return require, package
  end

  local shell = {}
  local running = {}
  function shell.resolveProgram(p)
    p = fs_.combine(p)
    if fs_.exists(p) and not fs_.isDir(p) then return p end
    if fs_.exists(p .. ".lua") then return p .. ".lua" end
    return nil
  end
  function shell.run(cmd, ...)
    local words = {}
    for w in tostring(cmd):gmatch("%S+") do words[#words + 1] = w end
    local args = { table.unpack(words, 2) }
    for i = 1, select("#", ...) do args[#args + 1] = select(i, ...) end
    local path = shell.resolveProgram(words[1] or "")
    if not path then
      G.printError("No such program")
      return false
    end
    local env = setmetatable({ shell = shell, arg = args }, { __index = G })
    env.require, env.package = makeRequire(env, fs_.getDir(path))
    local fn, err = load(c.fs:readFile(path), "@/" .. path, "t", env)
    if not fn then
      G.printError(err)
      sim:programError(c, err)
      return false
    end
    running[#running + 1] = path
    local ok, perr = xpcall(function() return fn(table.unpack(args)) end, debug.traceback)
    running[#running] = nil
    if not ok then
      G.printError(perr)
      sim:programError(c, perr)
      return false
    end
    return true
  end
  function shell.getRunningProgram() return running[#running] end
  function shell.dir() return "" end
  function shell.resolve(p) return fs_.combine(p) end
  function shell.exit() end
  G.shell = shell

  G.__mock = { makeRequire = makeRequire }
  G.http = c.http -- tests can attach a fake http API

  if c.kind == "turtle" then G.turtle = makeTurtle(sim, c) end
  if c.kind == "pocket" then G.pocket = {} end
  return G
end
