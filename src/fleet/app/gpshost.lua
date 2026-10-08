-- GPS host: answers GPS pings like `gps host`, but also tells the asker which
-- dimension it is in ({ x, y, z, dim = ... }; stock gps.locate still accepts it).
--
-- On startup and every 5 minutes it pings the other hosts and compares the measured
-- distances with the configured coordinates, so a mistyped coordinate shows up on
-- this screen. It also sends a small heartbeat to the control computer.

local U = require("lib.util")
local P = require("lib.proto")
local Net = require("lib.net")
local Log = require("lib.log")
local Up = require("lib.update")
local locate = require("lib.locate")

local CH = locate.CHANNEL

return function(cfg)
  local log = Log.new({ path = "/fleet/data/log.txt" })
  local dim = P.normDim(cfg.dim)
  local me = { x = cfg.x, y = cfg.y, z = cfg.z }
  local modem, side = U.findWirelessModem()
  if not modem then error("GPS host needs an ender modem attached", 0) end
  modem.open(CH)

  local net = Net.new({ secret = cfg.secret, dim = dim, window = cfg.replayWindow, maxBody = 200000 })
  net:open()
  local updater = Up.client({ net = net, serverId = cfg.serverId, log = log })
  local stats = { served = 0, lastPing = nil, peers = nil, checkAt = nil, verdict = "checking...", ackAt = nil }

  local function serve()
    while true do
      local _, s, ch, reply, msg, dist = os.pullEvent("modem_message")
      if s == side and ch == CH and msg == "PING" and dist then
        modem.transmit(reply, CH, { me.x, me.y, me.z, dim = dim })
        stats.served = stats.served + 1
        stats.lastPing = os.epoch("utc")
      end
    end
  end

  local function selfCheck()
    modem.transmit(CH, CH, "PING")
    local peers, seen = {}, {}
    local timer = os.startTimer(2)
    while true do
      local ev, s, ch, _, msg, dist = os.pullEvent()
      if ev == "modem_message" and s == side and ch == CH and dist and type(msg) == "table"
          and tonumber(msg[1]) and tonumber(msg[2]) and tonumber(msg[3]) then
        local p = { x = tonumber(msg[1]), y = tonumber(msg[2]), z = tonumber(msg[3]) }
        local key = p.x .. "," .. p.y .. "," .. p.z
        if not seen[key] then
          seen[key] = true
          local expect = math.sqrt((p.x - me.x) ^ 2 + (p.y - me.y) ^ 2 + (p.z - me.z) ^ 2)
          peers[#peers + 1] = { p = p, d = dist, expect = expect, ok = math.abs(expect - dist) < 0.5,
            dim = P.normDim(msg.dim) }
        end
      elseif ev == "timer" and s == timer then
        break
      end
    end
    stats.peers, stats.checkAt = peers, os.epoch("utc")
    local bad, points, close = 0, { me }, 0
    for _, pr in ipairs(peers) do
      if not pr.ok then bad = bad + 1 end
      if pr.d < 2 then close = close + 1 end
      points[#points + 1] = pr.p
    end
    if #peers == 0 then
      stats.verdict = "no other hosts heard (need 4 in this dimension)"
    elseif bad > 0 and bad == #peers and #peers >= 2 then
      stats.verdict = "MY coordinates look wrong (all peers disagree)"
    elseif bad > 0 then
      stats.verdict = bad .. " peer(s) disagree: check their coordinates"
    elseif #points < 4 then
      stats.verdict = (#points) .. " hosts total: need at least 4"
    elseif locate.spread(points) < 1e-3 then
      stats.verdict = "hosts are (nearly) coplanar: raise or lower one"
    elseif close > 0 then
      stats.verdict = "OK, but two hosts are almost touching: spread them out"
    else
      stats.verdict = "OK: " .. #points .. " hosts, good 3D spread"
    end
    log:info("self-check: %s", stats.verdict)
  end

  local function checker()
    sleep(1 + math.random() * 2)
    while true do
      selfCheck()
      sleep(300)
    end
  end

  local function heartbeat()
    while true do
      net:send(cfg.serverId, {
        type = P.HB, role = "gpshost", label = os.getComputerLabel(), x = me.x, y = me.y, z = me.z,
        served = stats.served, verdict = stats.verdict, ver = updater.ver,
      })
      sleep(20)
      updater:tick()
    end
  end

  local function netLoop()
    while true do
      local _, a, b, c = os.pullEvent("rednet_message")
      local from, body = net:unwrap(a, b, c)
      if from == cfg.serverId then
        if body.type == P.HB_ACK then
          stats.ackAt = os.epoch("utc")
          updater:serverVersion(body.ver)
        else
          updater:handle(from, body)
        end
      end
    end
  end

  local function screen()
    while true do
      local now = os.epoch("utc")
      term.setBackgroundColor(colors.black)
      term.clear()
      term.setCursorPos(1, 1)
      term.setTextColor(colors.yellow)
      print("TurtleGPS GPS host #" .. os.getComputerID() .. "  " .. updater.ver)
      term.setTextColor(colors.white)
      print("Dimension: " .. P.dimLabel(dim))
      print("Position:  " .. U.fmtPos(me))
      print("Served:    " .. stats.served .. " pings" ..
        (stats.lastPing and (" (last " .. U.age(now - stats.lastPing) .. " ago)") or ""))
      print("Server:    " .. (stats.ackAt and ("OK " .. U.age(now - stats.ackAt) .. " ago") or "no reply yet"))
      print("")
      term.setTextColor(stats.verdict:find("^OK") and colors.lime or colors.orange)
      print("Check: " .. stats.verdict)
      term.setTextColor(colors.lightGray)
      for i, pr in ipairs(stats.peers or {}) do
        if i > 8 then break end
        local line = string.format(" %-18s d=%7.2f %s", U.fmtPos(pr.p), pr.d,
          pr.ok and "ok" or string.format("EXPECTED %.2f", pr.expect))
        term.setTextColor(pr.ok and colors.lightGray or colors.red)
        print(line)
      end
      if updater.status then
        term.setTextColor(colors.cyan)
        print(updater.status)
      end
      term.setTextColor(colors.white)
      sleep(2)
    end
  end

  log:info("GPS host up at %s in %s", U.fmtPos(me), dim)
  parallel.waitForAny(serve, checker, heartbeat, netLoop, screen)
end
