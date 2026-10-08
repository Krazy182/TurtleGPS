-- Control-room computer: dispatcher + map server + monitor UI in one program.
--
-- Peripherals (any side): ender modem (required), advanced monitor (map),
-- optional: Player Detector, Chat Box (alerts to config.owner), speaker (chime).
-- The computer's own screen shows a console: log, rejected messages, key commands.

local P = require("lib.proto")
local U = require("lib.util")
local Net = require("lib.net")
local Log = require("lib.log")
local Up = require("lib.update")
local Fleet = require("server.fleet")
local Notify = require("server.notify")
local App = require("ui.app")
local J = require("lib.joincode")

--- Text scale: 1 (bigger, easier to touch) when the monitor still gets 60x24 characters,
--- else 0.5. An explicit monitor.scale in config wins.
local function chooseScale(mon, want)
  if type(want) == "number" then
    mon.setTextScale(want)
    return want
  end
  mon.setTextScale(1)
  local w, h = mon.getSize()
  if w >= 60 and h >= 24 then return 1 end
  mon.setTextScale(0.5)
  return 0.5
end

local function findMonitor(cfg)
  local side = cfg.monitor and cfg.monitor.side
  if side and peripheral.getType(side) == "monitor" then return peripheral.wrap(side), side end
  local best, bestSide
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local m = peripheral.wrap(name)
      if m.isColor() and not best then best, bestSide = m, name end
    end
  end
  return best, bestSide
end

return function(cfg)
  local log = Log.new({ path = "/fleet/data/log.txt", keep = 60 })
  local dim = P.normDim(cfg.dim) or "overworld"
  local net = Net.new({ secret = cfg.secret, dim = dim, window = cfg.replayWindow })
  if not net:open() then error("The control computer needs an ender modem attached", 0) end

  local fleet = Fleet.new(cfg, log)
  fleet:load()
  local notify = Notify.new(cfg, log)
  fleet.onAlert = function(a) notify:alert(a) end
  fleet.onResolve = function(a, note) notify:resolved(a, note) end
  local upd = Up.server({ net = net, log = log })

  local source = {
    view = function(_, d) return fleet:view(d, os.epoch("utc")) end,
    action = function(_, a) return fleet:action(a) end,
  }

  local mon, monSide = findMonitor(cfg)
  local ui
  local statePath = "/fleet/data/ui"
  if mon then
    local scale = chooseScale(mon, cfg.monitor and cfg.monitor.scale)
    ui = App.new({ term = mon, source = source, kind = "monitor", side = monSide, dim = dim,
      ascii = cfg.ui and cfg.ui.ascii, statePath = statePath })
    local mw, mh = mon.getSize()
    log:info("map on monitor '%s': %dx%d at text scale %s", monSide, mw, mh, tostring(scale))
  else
    log:warn("no advanced monitor found: map shown on this screen")
    ui = App.new({ term = term.current(), source = source, kind = "term", dim = dim,
      ascii = cfg.ui and cfg.ui.ascii, statePath = statePath })
  end

  local function netLoop()
    while true do
      local _, a, b, c = os.pullEvent("rednet_message")
      local from, body = net:unwrap(a, b, c)
      if from then
        if body.type == P.UPD_REQ then
          upd:handle(from, body)
        else
          local reply = fleet:handle(from, body, os.epoch("utc"))
          if reply then net:send(from, reply) end
        end
      end
    end
  end

  local function tickLoop()
    while true do
      local now = os.epoch("utc")
      fleet:tick(now)
      fleet:saveIfDue(now, 10)
      sleep(1)
    end
  end

  local function updateLoop()
    fleet.ver = upd:refresh().ver
    log:info("code version %s", fleet.ver)
    while true do
      upd:pump()
      sleep(0.5)
    end
  end

  local function console()
    if not mon then
      while true do os.pullEvent("fleet_never") end
    end
    local showJoinUntil = 0
    local function draw()
      local w, h = term.getSize()
      term.setBackgroundColor(colors.black)
      term.clear()
      term.setCursorPos(1, 1)
      term.setTextColor(colors.yellow)
      term.write(U.trunc(("TurtleGPS control #%d  %s  code %s"):format(os.getComputerID(), P.dimLabel(dim), fleet.ver), w))
      term.setCursorPos(1, 2)
      term.setTextColor(colors.lightGray)
      local s = net.stats
      term.write(U.trunc(("msgs in %d  out %d  rejected %d  updates sent %d"):format(s.recv, s.sent, s.rejected, upd.served), w))
      local y = 3
      -- one line per dimension: turtles, lost, GPS hosts
      local per = {}
      for _, t in pairs(fleet.turtles) do
        local d = per[t.dim or "?"] or { t = 0, lost = 0, g = 0, gl = 0 }
        per[t.dim or "?"] = d
        d.t = d.t + 1
        if t.link == "lost" then d.lost = d.lost + 1 end
      end
      for _, g in pairs(fleet.gps) do
        local d = per[g.dim or "?"] or { t = 0, lost = 0, g = 0, gl = 0 }
        per[g.dim or "?"] = d
        d.g = d.g + 1
        if g.link == "lost" then d.gl = d.gl + 1 end
      end
      local parts = {}
      local order = {}
      for _, d in ipairs(P.DIM_ORDER) do if per[d] then order[#order + 1] = d end end
      for _, d in ipairs(U.sortedKeys(per)) do
        local known = false
        for _, o in ipairs(P.DIM_ORDER) do if o == d then known = true end end
        if not known then order[#order + 1] = d end
      end
      for _, d in ipairs(order) do
        local x = per[d]
        parts[#parts + 1] = ("%s %d%s gps %d/%d"):format(P.dimShort(d), x.t, x.lost > 0 and ("(" .. x.lost .. " lost)") or "",
          x.g - x.gl, x.g)
      end
      term.setCursorPos(1, y)
      term.setTextColor(colors.white)
      term.write(U.trunc(#parts > 0 and table.concat(parts, "  ") or "no turtles or GPS hosts yet", w))
      y = y + 1
      if notify.lastError then
        term.setCursorPos(1, y)
        term.setTextColor(colors.orange)
        term.write(U.trunc("chat: " .. notify.lastError, w))
        y = y + 1
      end
      local r = s.last[1]
      if r then
        term.setCursorPos(1, y)
        term.setTextColor(colors.orange)
        term.write(U.trunc(("last rejected: #%d %s (%s ago)"):format(r.from, r.reason, U.age(os.epoch("utc") - r.t)), w))
        y = y + 1
      end
      local dn = fleet.denied[1]
      if dn then
        term.setCursorPos(1, y)
        term.setTextColor(colors.orange)
        term.write(U.trunc(("last denied: #%d %s: %s"):format(dn.from, dn.what, dn.why), w))
        y = y + 1
      end
      if showJoinUntil > os.epoch("utc") then
        term.setCursorPos(1, y)
        term.setTextColor(colors.yellow)
        term.write(U.trunc("Join code: " .. J.make(os.getComputerID(), cfg.secret), w))
        y = y + 1
      end
      term.setCursorPos(1, y)
      term.setTextColor(colors.cyan)
      term.write(U.trunc("[J] join code  [U] push update  [S] save  Ctrl+T stop", w))
      local lines = log.lines
      local room = h - y
      for i = math.max(1, #lines - room + 1), #lines do
        y = y + 1
        term.setCursorPos(1, y)
        local l = lines[i]
        term.setTextColor(l.level == "error" and colors.red or (l.level == "warn" and colors.orange or colors.white))
        term.write(U.trunc(l.text, w))
      end
    end
    local timer = os.startTimer(1)
    draw()
    while true do
      local ev, a = os.pullEvent()
      if ev == "timer" and a == timer then
        draw()
        timer = os.startTimer(1)
      elseif ev == "char" and (a == "u" or a == "U") then
        if upd:offer() then log:info("update %s offered to the fleet", fleet.ver) end
      elseif ev == "char" and (a == "j" or a == "J") then
        showJoinUntil = os.epoch("utc") + 30000
        draw()
      elseif ev == "char" and (a == "s" or a == "S") then
        fleet:save()
        log:info("saved")
      end
    end
  end

  log:info("control #%d up in %s; commanders: %s", os.getComputerID(), dim,
    #(cfg.commanders or {}) > 0 and table.concat(cfg.commanders, ",") or "none")
  parallel.waitForAny(netLoop, tickLoop, updateLoop, function() ui:run() end, console,
    function() notify:pump() end)
end
