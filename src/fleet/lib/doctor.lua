-- Self-check for any fleet computer. Each check yields { level, title, detail } where
-- level is "pass", "warn", "fail" or "info"; failures carry a hint on how to fix them.
-- Used by bin/doctor (prints) and bin/report (attaches to the bug report).

local P = require("lib.proto")
local U = require("lib.util")
local config = require("lib.config")
local Net = require("lib.net")
local locate = require("lib.locate")
local store = require("lib.store")
local sha2 = require("lib.sha2")
local Up = require("lib.update")

local D = {}

local function yield()
  os.queueEvent("fleet_yield")
  os.pullEvent("fleet_yield")
end

local function checkCode(add)
  local m = Up.readManifest()
  if not m then
    add("warn", "Code", "no /fleet/manifest: reinstall so updates can be checked")
    return
  end
  local bad, n = {}, 0
  for _, path in ipairs(U.sortedKeys(m.files)) do
    n = n + 1
    local data = store.readFile("/fleet/" .. path)
    if not data then bad[#bad + 1] = path .. " (missing)"
    elseif sha2.sha256Hex(data) ~= m.files[path] then bad[#bad + 1] = path .. " (edited)" end
    yield()
  end
  if #bad > 0 then
    add("warn", "Code", ("version %s, but %d file(s) differ: %s. Reinstall to repair."):format(
      m.ver, #bad, table.concat(bad, ", ")))
  else
    add("pass", "Code", ("version %s, %d files intact"):format(m.ver, n))
  end
end

local function checkDisk(add)
  local free = fs.getFreeSpace("/")
  local kb = math.floor(free / 1024)
  if free < 20000 then
    add("fail", "Disk", kb .. " KB free: logs and state can't be saved. Delete files or raise computerSpaceLimit.")
  elseif free < 100000 then
    add("warn", "Disk", kb .. " KB free")
  else
    add("pass", "Disk", kb .. " KB free")
  end
end

local function pingControl(cfg, add)
  local net = Net.new({ secret = cfg.secret, dim = P.normDim(cfg.dim) or "unknown", window = cfg.replayWindow })
  if not net:open() then return nil end
  local t0 = os.epoch("utc")
  net:send(cfg.serverId, { type = P.PING, role = cfg.role })
  local timer = os.startTimer(4)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" then
      local from, body = net:unwrap(a, b, c)
      if from == cfg.serverId and body.type == P.PONG then
        os.cancelTimer(timer)
        add("pass", "Control", ("#%d answered in %d ms (%s)"):format(from, os.epoch("utc") - t0, P.dimLabel(body.dim)))
        local mine = Up.myVersion()
        if body.ver and body.ver ~= "none" and body.ver ~= mine then
          add("info", "Update", ("control runs code %s, this computer %s: it updates itself shortly"):format(body.ver, mine))
        end
        if cfg.role == "turtle" and body.turtleAllowed == false then
          add("fail", "Allowlist", "control has a `turtles` allowlist without #" .. os.getComputerID() .. ": add it there")
        end
        if cfg.role == "pocket" and not body.commander then
          add("warn", "Allowlist", ("#%d is not in the control's `commanders` list: it can view but not command"):format(
            os.getComputerID()))
        end
        return body
      end
    elseif ev == "timer" and a == timer then
      add("fail", "Control", ("no reply from #%d in 4 s. Check: control running? serverId right? same secret? "
        .. "(the control's own screen shows 'last rejected: #%d bad signature' if the secret differs)"):format(
        cfg.serverId, os.getComputerID()))
      return nil
    end
  end
end

local function checkGps(cfg, add, optional)
  local pos, err, fixes = locate.locate(3, { all = true })
  fixes = pos and pos.fixes or fixes or {}
  if not pos then
    add(optional and "info" or "fail", "GPS", ("%s (heard %d host(s) in this dimension). Run /fleet/bin/gpscheck"):format(
      tostring(err), #fixes))
    return nil
  end
  add("pass", "GPS", ("%d, %d, %d in %s, from %d hosts"):format(pos.bx, pos.by, pos.bz,
    pos.dim and P.dimLabel(pos.dim) or "unknown dimension", pos.n))
  if pos.res > 0.5 then
    add("warn", "GPS", ("hosts disagree by %.1f blocks: a host's coordinates are wrong (gpscheck shows which)"):format(pos.res))
  end
  if pos.cond < 0.01 then add("warn", "GPS", "hosts are nearly on one plane: raise or lower one") end
  if not pos.dim then
    add("warn", "GPS", "hosts don't report a dimension (stock gps hosts?): run the TurtleGPS gpshost role on them")
  elseif cfg.dim and P.normDim(cfg.dim) ~= pos.dim then
    add("warn", "Dimension", ("config says %s but GPS says %s: fix dim in /fleet/config.lua"):format(
      P.dimLabel(P.normDim(cfg.dim)), P.dimLabel(pos.dim)))
  end
  return pos
end

local function checkGpsPeers(cfg, add)
  local modem, side = U.findWirelessModem()
  local ch = locate.CHANNEL
  local wasOpen = modem.isOpen(ch)
  if not wasOpen then modem.open(ch) end
  modem.transmit(ch, ch, "PING")
  local me = { x = cfg.x, y = cfg.y, z = cfg.z }
  local peers, seen, bad = {}, {}, {}
  local timer = os.startTimer(2)
  while true do
    local ev, s, c, _, msg, dist = os.pullEvent()
    if ev == "modem_message" and s == side and c == ch and dist and type(msg) == "table"
        and tonumber(msg[1]) and tonumber(msg[2]) and tonumber(msg[3]) then
      local p = { x = tonumber(msg[1]), y = tonumber(msg[2]), z = tonumber(msg[3]) }
      local key = p.x .. "," .. p.y .. "," .. p.z
      if not seen[key] then
        seen[key] = true
        peers[#peers + 1] = p
        local expect = math.sqrt((p.x - me.x) ^ 2 + (p.y - me.y) ^ 2 + (p.z - me.z) ^ 2)
        if math.abs(expect - dist) >= 0.5 then
          bad[#bad + 1] = ("%s (measured %.1f, coordinates say %.1f)"):format(U.fmtPos(p), dist, expect)
        end
      end
    elseif ev == "timer" and s == timer then
      break
    end
  end
  if not wasOpen then modem.close(ch) end
  local points = { me }
  for _, p in ipairs(peers) do points[#points + 1] = p end
  if #peers == 0 then
    add("fail", "GPS", "no other GPS hosts answer in this dimension: need 4 in total, all running and chunk-loaded")
  elseif #bad == #peers and #peers >= 2 then
    add("fail", "GPS", ("this host's x y z (%s) look wrong: all %d peers disagree. Re-run setup with the "
      .. "Targeted Block coordinates."):format(U.fmtPos(me), #peers))
  elseif #bad > 0 then
    add("warn", "GPS", "peer(s) with wrong coordinates: " .. table.concat(bad, "; "))
  elseif #points < 4 then
    add("fail", "GPS", ("%d hosts in total: need at least 4"):format(#points))
  elseif locate.spread(points) < 1e-3 then
    add("warn", "GPS", "hosts are (nearly) on one plane: raise or lower one")
  else
    add("pass", "GPS", ("%d other hosts agree with this host's coordinates %s"):format(#peers, U.fmtPos(me)))
  end
end

local function checkTurtle(cfg, add)
  local chunky
  for _, side in ipairs({ "left", "right" }) do
    if peripheral.getType(side) == "chunky" then chunky = side end
  end
  if chunky then
    add("pass", "Chunky", "Chunky upgrade on the " .. chunky .. ": keeps this chunk loaded")
  else
    add("warn", "Chunky", "no Chunky Turtle upgrade found: this turtle stops when you walk away")
  end
  if cfg.role ~= "turtle" then return end
  local fuel = turtle.getFuelLevel()
  if fuel == "unlimited" then
    add("pass", "Fuel", "unlimited (server config)")
  elseif fuel < 2 then
    add("fail", "Fuel", fuel .. ": it needs fuel to move one block and learn its heading. Put coal in and run 'refuel'")
  elseif fuel < (cfg.lowFuel or 500) then
    add("warn", "Fuel", fuel .. " (low)")
  else
    add("pass", "Fuel", tostring(fuel))
  end
  local tool = turtle.getItemDetail(16)
  if tool and tool.name:find("pickaxe") then
    add("pass", "Slot 16", tool.name .. " (swap tool for digging)")
  elseif tool then
    add("warn", "Slot 16", tool.name .. " is in slot 16, which is reserved for the swap pickaxe")
  else
    add("warn", "Slot 16", "empty: put a diamond pickaxe there before milestone 3 (digging jobs)")
  end
  local nav = store.load("/fleet/data/nav", nil)
  if type(nav) == "table" and nav.x then
    add("info", "Saved position", ("%s facing %s"):format(U.fmtPos(nav), nav.h and P.HEADING_NAME[nav.h] or "?"))
  end
end

local function explainChat(err)
  err = tostring(err)
  if err:find("incorrect player") then return "player is offline or the owner name is misspelled" end
  if err:find("NOT_SAME_DIMENSION") then return "server's AP config has chatBoxMultiDimensional = false" end
  if err:lower():find("cooldown") then return "Chat Box on cooldown: run doctor again in a few seconds" end
  return err
end

local function checkControl(cfg, add)
  local mon, any
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      any = name
      if peripheral.call(name, "isColor") then mon = name; break end
    end
  end
  if mon then
    local m = peripheral.wrap(mon)
    local w, h = m.getSize()
    local scale = m.getTextScale and m.getTextScale() or "?"
    add("pass", "Monitor", ("advanced monitor '%s': %dx%d characters at text scale %s"):format(mon, w, h, tostring(scale)))
  elseif any then
    add("warn", "Monitor", "monitor '" .. any .. "' is not an advanced monitor (no colour or touch): use advanced ones")
  else
    add("warn", "Monitor", "no monitor attached: the map shows on this computer's screen")
  end

  local chat = peripheral.find("chatBox")
  if not chat then
    add("info", "Chat Box", "not attached: alerts only show on the monitor")
  elseif not cfg.owner then
    add("warn", "Chat Box", "attached, but `owner` isn't set in /fleet/config.lua, so alerts aren't sent")
  else
    local ok, res, err = pcall(chat.sendMessageToPlayer, "doctor test: Chat Box alerts reach you", cfg.owner, "TurtleGPS")
    if ok and res then
      add("pass", "Chat Box", "test message sent to " .. cfg.owner)
    else
      add("warn", "Chat Box", "test message to " .. cfg.owner .. " failed: " .. explainChat(ok and err or res))
    end
  end

  local speaker = peripheral.find("speaker")
  if speaker then
    pcall(speaker.playNote, "bell", 1, 12)
    add("pass", "Speaker", "attached (you should have heard a chime)")
  else
    add("info", "Speaker", "not attached: no alert chime")
  end

  local det = peripheral.find("playerDetector")
  if not det then
    add("info", "Player Detector", "not attached (milestone 2 shows players with it; pockets can report instead)")
  else
    local okList, online = pcall(det.getOnlinePlayers)
    local who = cfg.owner or (okList and type(online) == "table" and online[1])
    if not who then
      add("info", "Player Detector", "attached; set `owner` to test it")
    else
      local ok, pos = pcall(det.getPlayerPos, who)
      if not ok then
        local msg = tostring(pos)
        if msg:find("disabled") then
          add("warn", "Player Detector", "getPlayerPos is disabled in the server's Advanced Peripherals config "
            .. "(playerSpy). Milestone 2 then uses pocket GPS instead.")
        else
          add("warn", "Player Detector", msg)
        end
      elseif type(pos) == "table" and pos.x then
        add("pass", "Player Detector", ("sees %s at %d, %d, %d in %s"):format(who, pos.x, pos.y, pos.z,
          P.dimLabel(P.normDim(pos.dimension))))
      else
        add("warn", "Player Detector", "can't see " .. who .. " (offline, or in another dimension with "
          .. "playerDetMultiDimensional off)")
      end
    end
  end

  if #(cfg.commanders or {}) == 0 then
    add("info", "Commanders", "no pocket IDs allowed yet (needed from milestone 2)")
  else
    add("pass", "Commanders", "pockets allowed to command: #" .. table.concat(cfg.commanders, ", #"))
  end
  local garages = {}
  for d, g in pairs(cfg.garages or {}) do
    if type(g) == "table" and g.x then garages[#garages + 1] = ("%s %s"):format(P.dimShort(P.normDim(d) or d), U.fmtPos(g)) end
  end
  if #garages == 0 then
    add("info", "Garages", "none set: add garages = { overworld = { x=, y=, z= } } to /fleet/config.lua")
  else
    add("pass", "Garages", table.concat(garages, "; "))
  end
  local db = store.load("/fleet/data/fleet.db", nil)
  if type(db) == "table" then
    local t, lost, g = 0, 0, 0
    for _, r in pairs(db.turtles or {}) do
      t = t + 1
      if r.link == "lost" then lost = lost + 1 end
    end
    for _ in pairs(db.gps or {}) do g = g + 1 end
    add("info", "Fleet", ("knows %d turtle(s) (%d lost) and %d GPS host(s)"):format(t, lost, g))
  end
end

--- Runs every check that applies to this computer. opts.out(result) is called as each
--- result arrives. Returns the list of results and counts { pass, warn, fail, info }.
function D.run(opts)
  opts = opts or {}
  local results, counts = {}, { pass = 0, warn = 0, fail = 0, info = 0 }
  local function add(level, title, detail)
    local r = { level = level, title = title, detail = detail }
    results[#results + 1] = r
    counts[level] = counts[level] + 1
    if opts.out then opts.out(r) end
  end

  local kind = turtle and "turtle" or (pocket and "pocket computer" or "computer")
  add("info", "Computer", ("#%d %s (%s), %s"):format(os.getComputerID(), os.getComputerLabel() or "no label", kind,
    _HOST or os.version()))

  local cfg, err = config.load()
  if not cfg then
    add("fail", "Config", "cannot read /fleet/config.lua (" .. tostring(err) .. "): run /fleet/bin/setup")
    return results, counts
  end
  local problems = config.problems(cfg)
  for _, p in ipairs(problems) do add("fail", "Config", p .. ": run /fleet/bin/setup") end
  if #problems > 0 then return results, counts end
  add("pass", "Config", "role " .. cfg.role .. (cfg.dim and (", " .. P.dimLabel(P.normDim(cfg.dim))) or "")
    .. (cfg.serverId and (", control #" .. cfg.serverId) or ""))

  local startup = store.readFile("/startup.lua")
  if startup and startup:find("/fleet/boot.lua", 1, true) then
    add("pass", "Startup", "/startup.lua starts TurtleGPS")
  else
    add("warn", "Startup", "/startup.lua doesn't start TurtleGPS on boot: run /fleet/bin/setup")
  end
  checkCode(add)
  checkDisk(add)

  local modem, side = U.findWirelessModem()
  if not modem then
    add("fail", "Modem", "no wireless modem attached: attach an ENDER modem")
  else
    add("pass", "Modem", "wireless modem on " .. side .. " (it must be an ender modem)")
  end

  if modem and cfg.role ~= "control" then pingControl(cfg, add) end
  if modem then
    if cfg.role == "gpshost" then checkGpsPeers(cfg, add)
    else checkGps(cfg, add, cfg.role == "control") end
  end
  if turtle then checkTurtle(cfg, add) end
  if cfg.role == "control" then checkControl(cfg, add) end
  if cfg.role == "pocket" and not cfg.owner then
    add("warn", "Owner", "set owner = \"YourName\" so the map can show you")
  end
  return results, counts
end

local TAGS = { pass = "OK  ", warn = "WARN", fail = "FAIL", info = "info" }
D.TAGS = TAGS

function D.format(r)
  return ("[%s] %s: %s"):format(TAGS[r.level], r.title, r.detail or "")
end

return D
