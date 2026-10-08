-- Turtle agent: finds its position and heading, then heartbeats telemetry to the
-- control computer every few seconds. Only messages signed with the fleet secret AND
-- sent by the configured control computer are obeyed.
--
-- Hardware: Chunky Turtle upgrade on one side, ender modem on the other.
-- Slot 16 is reserved for the swap tool (diamond pickaxe) used by later milestones.

local P = require("lib.proto")
local U = require("lib.util")
local Net = require("lib.net")
local Log = require("lib.log")
local Up = require("lib.update")
local Nav = require("turtle.nav")

return function(cfg)
  local log = Log.new({ path = "/fleet/data/log.txt" })
  local nav = Nav.new({ log = log, dim = cfg.dim })
  nav:load()

  local state = {
    status = "booting", job = nil, msg = nil,
    ackAt = nil, sentAt = nil, serverVer = nil,
  }
  local net = Net.new({
    secret = cfg.secret, dim = function() return nav.dim end,
    window = cfg.replayWindow, maxBody = 200000,
  })
  net:open()
  local updater = Up.client({
    net = net, serverId = cfg.serverId, log = log,
    canApply = function() return state.status == "idle" end,
  })

  local reserved = {}
  for _, s in ipairs(cfg.reservedSlots or {}) do reserved[s] = true end

  local function inventory()
    local used, total = 0, 0
    for s = 1, 16 do
      if not reserved[s] then
        total = total + 1
        if turtle.getItemCount(s) > 0 then used = used + 1 end
      end
    end
    return used, total
  end

  local function fuel()
    local f = turtle.getFuelLevel()
    if f == "unlimited" then return -1, -1 end
    return f, turtle.getFuelLimit()
  end

  local function heartbeat()
    local t = nav:telemetry()
    local f, fmax = fuel()
    local used, total = inventory()
    return {
      type = P.HB, role = "turtle", label = os.getComputerLabel(), dim = t.dim,
      x = t.x, y = t.y, z = t.z, h = t.h, fix = t.fix, fixAge = t.fixAge, gpsErr = t.gpsErr,
      fuel = f, fuelMax = fmax, reserve = cfg.lowFuel,
      inv = { used, total },
      status = state.status, job = state.job, msg = state.msg,
      ver = updater.ver, up = math.floor(os.clock()),
    }
  end

  local function hbLoop()
    while true do
      if net:send(cfg.serverId, heartbeat()) then state.sentAt = os.epoch("utc") end
      sleep(cfg.heartbeat)
    end
  end

  local function netLoop()
    while true do
      local ev, a, b, c = os.pullEvent()
      if ev == "rednet_message" then
        local from, body = net:unwrap(a, b, c)
        if from == cfg.serverId then
          if body.type == P.HB_ACK then
            state.ackAt = os.epoch("utc")
            state.serverVer = body.ver
            updater:serverVersion(body.ver)
          else
            updater:handle(from, body)
          end
        elseif from then
          log:warn("ignored %s from #%d: only #%d may command this turtle", body.type, from, cfg.serverId)
        end
      elseif ev == "peripheral" or ev == "peripheral_detach" then
        net:open()
      end
    end
  end

  local function mainLoop()
    state.status = "locating"
    local ok, why = nav:calibrate()
    if ok then
      log:info("at %s facing %s (%s)", U.fmtPos(nav), P.HEADING_NAME[nav.h], why)
      state.msg = nil
    else
      log:warn("calibrate: %s", why)
      state.msg = why
    end
    state.status = "idle"
    local lastCal = os.epoch("utc")
    while true do
      sleep(2)
      updater:tick()
      local now = os.epoch("utc")
      if not nav.h or not nav:known() then
        if now - lastCal > 30000 then
          lastCal = now
          ok, why = nav:calibrate()
          state.msg = (not ok) and why or nil
        end
      elseif not nav.fixAt or now - nav.fixAt > cfg.gpsEvery * 1000 then
        nav:fix()
      end
    end
  end

  local function line(y, label, value, col)
    term.setCursorPos(1, y)
    term.setTextColor(colors.lightGray)
    term.write(U.pad(label, 8))
    term.setTextColor(col or colors.white)
    term.write(tostring(value))
  end

  local function screen()
    while true do
      local now = os.epoch("utc")
      local t = nav:telemetry()
      local f, fmax = fuel()
      local used, total = inventory()
      term.setBackgroundColor(colors.black)
      term.clear()
      term.setCursorPos(1, 1)
      term.setTextColor(colors.yellow)
      term.write(U.trunc("#" .. os.getComputerID() .. " " .. (os.getComputerLabel() or "turtle") .. "  " .. updater.ver, 39))
      line(2, "Dim", P.dimLabel(t.dim))
      line(3, "Status", state.status, state.status == "idle" and colors.lime or colors.white)
      line(4, "Pos", t.x and U.fmtPos(t) or "unknown", t.x and colors.white or colors.red)
      line(5, "Facing", t.h and P.HEADING_NAME[t.h] or "unknown", t.h and colors.white or colors.red)
      local fixText = t.fix == "none" and ("none: " .. tostring(t.gpsErr or "?"))
        or (t.fix .. (t.fixAge and (" (gps " .. U.age(t.fixAge * 1000) .. " ago)") or ""))
      line(6, "Fix", fixText, t.fix == "none" and colors.red or colors.white)
      line(7, "Fuel", f < 0 and "unlimited" or (f .. " / " .. fmax), (f >= 0 and f < cfg.lowFuel) and colors.orange or colors.white)
      line(8, "Inv", used .. " / " .. total .. " slots", used >= total and colors.orange or colors.white)
      local link, lc
      if not net:isUp() then link, lc = "NO MODEM", colors.red
      elseif state.ackAt and now - state.ackAt < (cfg.heartbeat * 3 + 2) * 1000 then
        link, lc = "OK (#" .. cfg.serverId .. ")", colors.lime
      elseif state.ackAt then
        link, lc = "no reply for " .. U.age(now - state.ackAt), colors.orange
      else
        link, lc = "no reply: check serverId/secret", colors.red
      end
      line(9, "Server", link, lc)
      if state.msg then line(10, "Note", U.trunc(state.msg, 31), colors.orange) end
      if updater.status then line(11, "Update", U.trunc(updater.status, 31), colors.cyan) end
      local last = log.lines[#log.lines]
      if last then
        term.setCursorPos(1, 13)
        term.setTextColor(colors.gray)
        term.write(U.trunc(last.text, 39))
      end
      sleep(1)
    end
  end

  log:info("turtle agent starting, server #%d", cfg.serverId)
  parallel.waitForAny(hbLoop, netLoop, mainLoop, screen)
end
