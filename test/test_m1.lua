local H = require("helpers")

local function db(sim)
  return sim.ser.unserialize(sim.control.fs:readFile("/fleet/data/fleet.db") or "nil")
end

return {
  { "heartbeats from three dimensions reach the control computer", function()
    local sim = H.fleet()
    sim:run(25)
    H.noErrors(sim)
    local d = H.ok(db(sim), "fleet.db saved")
    for _, t in ipairs(sim.turtles) do
      local r = H.ok(d.turtles[t.id], "turtle " .. t.id .. " known")
      H.eq(r.dim, t.dim, "dim"); H.eq(r.x, t.pos.x); H.eq(r.y, t.pos.y); H.eq(r.z, t.pos.z)
      H.eq(r.h, t.heading, "heading"); H.eq(r.status, "idle"); H.eq(r.link, "ok")
      H.eq(r.invTotal, 15); H.eq(r.invUsed, 0)
      H.eq(r.fix, "gps")
    end
    H.eq(#sim.turtles[1].screen:dumpText() > 0, true)
    H.ok(sim.turtles[1].screen:contains("Server  OK (#1)"), sim.turtles[1].screen:dumpText())
    -- GPS hosts report in too
    local n = 0
    for _ in pairs(d.gps) do n = n + 1 end
    H.eq(n, 12, "gps hosts known")
  end },
  { "monitor shows turtle dots, list and dimension switcher", function()
    local sim = H.fleet()
    sim:run(20)
    H.noErrors(sim)
    local mon = sim:monitor(sim.control)
    local txt = mon:dumpText()
    H.ok(mon:contains("Overworld (1)"), txt)
    H.ok(mon:contains("#10 T10"), txt)
    H.ok(mon:contains("GPS: 4 hosts OK"), txt)
    -- turtle 10 at x=5,z=5 facing east: an east triangle somewhere on the map
    H.ok(txt:find("►"), "east-facing turtle glyph drawn")
    -- switch to the nether with the ► button next to the dimension name
    local x, y = mon:find("Overworld (1)")
    sim:touch(sim.control, "top", x + 16, y)
    sim:run(1.5)
    H.ok(mon:contains("Nether (1)"), mon:dumpText())
    H.ok(mon:contains("#11 T11"), mon:dumpText())
    H.ok(mon:dumpText():find("▼"), "south-facing nether turtle drawn")
    mon:dumpRaw("test/out/m1_monitor.json")
  end },
  { "tap a turtle to see status", function()
    local sim = H.fleet()
    sim:run(20)
    local mon = sim:monitor(sim.control)
    local x, y = mon:find("T10")
    H.ok(x and y > 1, "turtle on map")
    sim:touch(sim.control, "top", x - 1, y)
    sim:run(1.5)
    local txt = mon:dumpText()
    H.ok(mon:contains("#10 T10"), txt)
    H.ok(mon:contains("Pos  5, 65, 5"), txt)
    H.ok(mon:contains("Fuel 1998 / 100000"), txt)
    H.ok(mon:contains("Inv  0 / 15 slots"), txt)
    H.ok(mon:contains("Center"), txt)
    mon:dumpRaw("test/out/m1_detail.json")
  end },
  { "silent turtle goes stale, then LOST with alert + chat; recovers", function()
    local sim = H.fleet()
    sim:run(50) -- past the post-boot grace period
    local t = sim.turtles[2]
    sim:unload(t)
    sim:run(20)
    local d = sim.control
    local mon = sim:monitor(d)
    sim:run(30)
    H.noErrors(sim)
    local found
    for _, c in ipairs(sim.chat) do if c.msg:find("#11 T11 LOST") then found = c end end
    H.ok(found, "chat alert sent")
    H.eq(found.to, "Steve")
    H.ok(#sim.sounds > 0, "speaker chimed")
    H.ok(mon:contains("ALERTS 1"), mon:dumpText())
    H.ok(mon:find("LOST in Nether"), mon:dumpText())
    sim:load(t)
    sim:run(10)
    H.ok(mon:contains("ALERTS 0"), mon:dumpText())
    local back
    for _, c in ipairs(sim.chat) do if c.msg:find("back online") then back = true end end
    H.ok(back, "recovery message")
  end },
  { "server restart does not raise false LOST alerts", function()
    local sim = H.fleet()
    sim:run(30)
    sim:unload(sim.control)
    sim:run(120)
    sim:load(sim.control)
    sim:run(60)
    H.noErrors(sim)
    for _, c in ipairs(sim.chat) do
      H.ok(not c.msg:find("LOST"), "unexpected alert: " .. c.msg)
    end
    local d = db(sim)
    H.eq(d.turtles[10].link, "ok")
  end },
  { "low fuel and full inventory raise alerts", function()
    local sim = H.fleet({ turtles = {
      { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1, fuel = 100 },
      { id = 13, dim = "overworld", pos = { 9, 65, 5 }, heading = 1,
        inv = (function()
          local inv = {}
          for s = 1, 15 do inv[s] = { name = "minecraft:cobblestone", count = 64 } end
          inv[16] = { name = "minecraft:diamond_pickaxe", count = 1 }
          return inv
        end)() },
    } })
    sim:run(20)
    H.noErrors(sim)
    local msgs = {}
    for _, c in ipairs(sim.chat) do msgs[#msgs + 1] = c.msg end
    local all = table.concat(msgs, "\n")
    H.ok(all:find("#10 T10 low fuel: %d+"), all)
    H.ok(all:find("#13 T13 inventory full"), all)
  end },
}
