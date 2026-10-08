local H = require("helpers")

local function navOf(sim, c)
  return sim.ser.unserialize(c.fs:readFile("/fleet/data/nav") or "nil")
end

return {
  { "turtles in all three dimensions locate and calibrate heading", function()
    local sim = H.fleet()
    sim:run(15)
    H.noErrors(sim)
    for _, t in ipairs(sim.turtles) do
      local n = H.ok(navOf(sim, t), "nav saved for #" .. t.id)
      H.eq(n.x, t.pos.x, "x #" .. t.id); H.eq(n.y, t.pos.y, "y #" .. t.id); H.eq(n.z, t.pos.z, "z #" .. t.id)
      H.eq(n.h, t.heading, "heading #" .. t.id)
      H.eq(n.dim, t.dim, "dim #" .. t.id)
    end
    -- calibration moved and came back; fuel used
    H.eq(sim.turtles[1].turtle.fuel, 1998)
  end },
  { "heading kept without moving when saved position matches", function()
    local sim = H.fleet()
    sim:run(10)
    local t = sim.turtles[1]
    local fuel = t.turtle.fuel
    sim:unload(t); sim:load(t)
    sim:run(10)
    H.noErrors(sim)
    H.eq(t.turtle.fuel, fuel, "no calibration moves after reboot")
    H.eq(navOf(sim, t).h, 1)
  end },
  { "boxed-in turtle calibrates by moving back", function()
    local sim = H.fleet({ turtles = {} })
    sim.world:set("overworld", 5, 65, 4, "minecraft:stone") -- in front (facing north)
    local t = H.turtle(sim, { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 0 })
    sim:run(12)
    H.noErrors(sim)
    local n = navOf(sim, t)
    H.eq(n.h, 0); H.eq(n.z, 5)
    H.eq(t.pos.z, 5, "back where it started")
  end },
  { "no GPS in dimension: position unknown, reported on screen", function()
    local sim = H.fleet({ gps = false, turtles = { { id = 10, dim = "the_end", pos = { 1, 61, 1 } } } })
    sim:run(8)
    H.noErrors(sim)
    local t = sim.turtles[1]
    H.ok(t.screen:contains("Pos     unknown"), t.screen:dumpText())
    H.ok(t.screen:contains("need 4 GPS hosts"), t.screen:dumpText())
  end },
  { "gps host self-check flags a mistyped coordinate", function()
    local sim = H.Sim.new()
    local hosts = H.gps(sim, "overworld", 0, 90, 0, 100)
    -- host 103 really is at 0,98,0 but its owner typed y=96
    hosts[4].fs:writeFile("/fleet/config.lua", H.configText({
      role = "gpshost", secret = H.SECRET, serverId = 1, dim = "overworld", x = 0, y = 96, z = 0 }))
    sim:unload(hosts[4]); sim:load(hosts[4])
    sim:run(6)
    H.noErrors(sim)
    H.ok(hosts[4].screen:contains("MY coordinates look wrong"), hosts[4].screen:dumpText())
    H.ok(hosts[1].screen:contains("1 peer(s) disagree"), hosts[1].screen:dumpText())
  end },
  { "gpscheck lists hosts and position", function()
    local sim = H.fleet({ turtles = {} })
    local c = sim:add({ id = 60, dim = "the_nether", pos = { 20, 70, 20 },
      peripherals = { back = { "modem", ender = true } },
      files = { ["/startup.lua"] = 'shell.run("/fleet/bin/gpscheck.lua")' } })
    sim:run(5)
    H.noErrors(sim)
    H.ok(c.screen:contains("Heard 4 host(s)"), c.screen:dumpText())
    H.ok(c.screen:contains("Position: 20, 70, 20  (Nether)"), c.screen:dumpText())
  end },
}
