-- Failure modes and load: things that would be painful to discover in-game.
local H = require("helpers")

local function readHost(p)
  local f = assert(io.open(p, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function db(sim)
  return sim.ser.unserialize(sim.control.fs:readFile("/fleet/data/fleet.db") or "nil")
end

return {
  { "dead reckoning matches the real position over a long path", function()
    local sim = H.fleet({ turtles = {} })
    local t = H.turtle(sim, { id = 10, dim = "overworld", pos = { 5, 66, 5 }, heading = 2, boot = false })
    t.fs:writeFile("/startup.lua", [[
      package.path = "/fleet/?.lua;" .. package.path
      local Nav = require("turtle.nav")
      local nav = Nav.new({ dim = "overworld" })
      assert(nav:calibrate())
      local steps = { "forward", "forward", "turnLeft", "forward", "up", "up", "turnLeft", "turnLeft",
        "forward", "forward", "forward", "down", "turnRight", "back", "back", "forward" }
      for i = 1, 3 do
        for _, s in ipairs(steps) do assert(nav[s](nav), s) end
      end
      local p = nav:pos()
      local h = fs.open("/result", "w")
      h.write(p.x .. "," .. p.y .. "," .. p.z .. "," .. nav.h .. "," .. nav.moves)
      h.close()
      local fixed = nav:fix()
      h = fs.open("/drift", "w")
      h.write(tostring(nav.drift))
      h.close()
    ]])
    sim:boot(t)
    sim:run(60)
    H.noErrors(sim)
    local x, y, z, hd = t.fs:readFile("/result"):match("^(-?%d+),(-?%d+),(-?%d+),(%d)")
    H.eq(tonumber(x), t.pos.x); H.eq(tonumber(y), t.pos.y); H.eq(tonumber(z), t.pos.z)
    H.eq(tonumber(hd), t.heading)
    H.eq(t.fs:readFile("/drift"), "nil", "GPS agrees with dead reckoning")
  end },
  { "turtle picked up and placed elsewhere re-learns position and heading", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    sim:run(15)
    local t = sim.turtles[1]
    sim:unload(t)
    sim.world:setOccupant("overworld", 5, 65, 5, nil)
    t.pos, t.heading = { x = -30, y = 70, z = 12 }, 3
    sim.world:setOccupant("overworld", -30, 70, 12, t)
    sim:load(t)
    sim:run(20)
    H.noErrors(sim)
    local r = db(sim).turtles[10]
    H.eq(r.x, -30); H.eq(r.y, 70); H.eq(r.z, 12); H.eq(r.h, 3)
  end },
  { "30 turtles and 3 constellations for 5 minutes: no errors, light CPU, no dropped events", function()
    local list = {}
    local dims = { "overworld", "the_nether", "the_end" }
    local ys = { overworld = 65, the_nether = 50, the_end = 61 }
    for i = 1, 30 do
      local d = dims[(i - 1) % 3 + 1]
      list[i] = { id = 200 + i, dim = d, pos = { (i % 6) * 3 - 8, ys[d], math.floor(i / 6) * 3 - 8 }, heading = i % 4 }
    end
    local sim = H.fleet({ turtles = list })
    sim:run(300)
    H.noErrors(sim)
    local c = sim.control
    H.eq(c.dropped, nil, "control dropped events (queue overflow)")
    local perSecond = c.instructions / 300
    H.ok(perSecond < 3e6, ("control uses %.1fM instructions/s"):format(perSecond / 1e6))
    H.ok(c.maxBurst < 2e7, ("control burst %.1fM instructions"):format(c.maxBurst / 1e6))
    local d = db(sim)
    local n = 0
    for _, r in pairs(d.turtles) do
      n = n + 1
      H.eq(r.link, "ok", "turtle " .. r.id)
    end
    H.eq(n, 30)
    H.ok(#c.fs:readFile("/fleet/data/fleet.db") < 40000, "fleet.db stays small")
    for _, t in ipairs(sim.turtles) do H.eq(t.dropped, nil, "turtle " .. t.id .. " dropped events") end
  end },
  { "logs stay bounded", function()
    local sim = H.fleet({ turtles = {} })
    H.lastSim = sim
    local c = sim.control
    sim:run(5)
    local Log = H.lib(c, "lib.log")
    local log = Log.new({ path = "/fleet/data/test.log", maxBytes = 2000 })
    for i = 1, 500 do log:info("line %d with some padding to make it longer", i) end
    H.ok(c.fs:readFile("/fleet/data/test.log"):len() <= 2100)
    H.ok(c.fs:readFile("/fleet/data/test.log.old"))
  end },
  { "full disk on the control computer: keeps running, says why", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    sim:run(15)
    local c = sim.control
    c.fs.capacity = c.fs:used() + 200
    sim:run(40)
    H.noErrors(sim)
    H.ok(c.screen:contains("saving fleet state failed"), c.screen:dumpText())
    H.ok(sim:monitor(c):contains("#10 T10"), "map still live")
  end },
  { "full disk on a turtle: keeps reporting", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    local t = sim.turtles[1]
    t.fs.capacity = t.fs:used() + 50
    sim:unload(t); sim:load(t)
    sim:run(30)
    H.noErrors(sim)
    H.eq(db(sim).turtles[10].link, "ok")
  end },
  { "reinstalling keeps config and data, removes obsolete files, reboots into the app", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    sim:run(10)
    local t = sim.turtles[1]
    t.fs:writeFile("/fleet/app/obsolete.lua", "-- old")
    t.fs:writeFile("/install.lua", readHost("dist/install.lua"))
    t.fs:writeFile("/startup.lua", 'shell.run("/install.lua")')
    sim:unload(t); sim:load(t)
    sim:run(15)
    H.noErrors(sim)
    H.eq(t.fs:readFile("/fleet/app/obsolete.lua"), nil)
    H.ok(t.fs:readFile("/fleet/config.lua"):find("turtle"), "config kept")
    H.ok(t.fs:readFile("/fleet/data/nav"), "data kept")
    H.eq(t.fs:readFile("/startup.lua"), 'shell.run("/fleet/boot.lua")\n')
    H.ok(t.screen:contains("Server  OK"), t.screen:dumpText())
  end },
  { "config problems are explained instead of crashing", function()
    local sim = H.Sim.new()
    local cases = {
      { nil, "cannot read /fleet/config.lua" },
      { "return { role = 'turtle', secret = 'x' ", "cannot read /fleet/config.lua" },
      { "return { role = 'turtle', secret = 'short', serverId = 1 }", "secret must be at least 8" },
      { "return { role = 'turtle', secret = 'longenough' }", "serverId must be" },
      { "return { role = 'gpshost', secret = 'longenough', serverId = 1, dim = 'overworld' }", "gpshost needs x, y, z" },
      { "return { role = 'miner', secret = 'longenough', serverId = 1 }", "role must be" },
    }
    for i, case in ipairs(cases) do
      local c = sim:add({ id = 300 + i, peripherals = { back = { "modem", ender = true } },
        files = case[1] and { ["/fleet/config.lua"] = case[1] } or {} })
      sim:run(1)
      H.ok(c.screen:contains(case[2]), c.screen:dumpText())
      H.ok(c.screen:contains("/fleet/bin/setup"), c.screen:dumpText())
    end
    H.noErrors(sim)
  end },
  { "turtle with no modem and unlimited fuel", function()
    local sim = H.fleet({ turtles = {} })
    local t = H.turtle(sim, { id = 10, dim = "overworld", pos = { 5, 65, 5 },
      equip = { left = "advancedperipherals:chunk_controller" } })
    sim:run(10)
    H.noErrors(sim)
    H.ok(t.screen:contains("NO MODEM"), t.screen:dumpText())
    local u = H.turtle(sim, { id = 11, dim = "overworld", pos = { 9, 65, 5 } })
    u.turtle.fuelLimit = "unlimited"
    sim:unload(u); sim:load(u)
    sim:run(15)
    H.noErrors(sim)
    H.ok(u.screen:contains("Fuel    unlimited"), u.screen:dumpText())
    H.eq(db(sim).turtles[11].fuel, -1)
  end },
  { "control without a monitor draws the map on its own screen", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    sim.control.peripherals.top = nil
    sim:unload(sim.control); sim:load(sim.control)
    sim:run(15)
    H.noErrors(sim)
    H.ok(sim.control.screen:contains("Overworld (1)"), sim.control.screen:dumpText())
  end },
  { "pocket placeholder updates itself over the air", function()
    local sim = H.fleet({ turtles = {} })
    local p = sim:add({ id = 50, kind = "pocket", owner = "Steve", peripherals = { back = { "modem", ender = true } },
      files = { ["/fleet/config.lua"] = H.configText({ role = "pocket", secret = H.SECRET, serverId = 1, owner = "Steve" }) } })
    sim:run(15)
    H.ok(p.screen:contains("Control #1: OK"), p.screen:dumpText())
    local c = sim.control
    c.fs:writeFile("/fleet/app/pocket.lua", c.fs:readFile("/fleet/app/pocket.lua") .. "\n-- v2\n")
    sim:unload(c); sim:load(c)
    sim:run(60)
    H.noErrors(sim)
    H.ok(p.fs:readFile("/fleet/app/pocket.lua"):find("%-%- v2"), "pocket got the new code")
  end },
  { "oversized and foreign rednet traffic does not disturb the control computer", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    sim:add({ id = 66, dim = "overworld", pos = { 50, 70, 50 }, install = false,
      peripherals = { back = { "modem", ender = true } },
      files = { ["/startup.lua"] = [[
        rednet.open("back")
        rednet.send(1, { v = 1, f = 66, t = 1, ts = os.epoch("utc"), n = "x", b = string.rep("A", 70000), m = "0" }, "turtlegps")
        for i = 1, 600 do
          rednet.broadcast({ chat = "hello " .. i }, "someone_elses_protocol")
          rednet.send(1, "junk " .. i)
          sleep(0.1)
        end
      ]] } })
    sim:run(70)
    H.noErrors(sim)
    H.ok(sim.control.screen:contains("rejected 1"), sim.control.screen:dumpText())
    H.eq(sim.control.dropped, nil, "no dropped events")
    H.eq(db(sim).turtles[10].link, "ok")
  end },
}
