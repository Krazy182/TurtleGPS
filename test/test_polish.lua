-- Behaviour added while polishing milestone 1.
local H = require("helpers")

local function db(sim)
  return sim.ser.unserialize(sim.control.fs:readFile("/fleet/data/fleet.db") or "nil")
end

local function chatText(sim)
  local t = {}
  for _, c in ipairs(sim.chat) do t[#t + 1] = c.msg end
  return table.concat(t, "\n")
end

return {
  { "monitor text scale is chosen from the monitor size", function()
    for _, case in ipairs({ { 8, 6, 82, 40 }, { 8, 5, 82, 33 }, { 4, 3, 79, 38 }, { 3, 2, 57, 24 } }) do
      local sim = H.fleet({ monW = case[1], monH = case[2], turtles = {}, gps = false })
      sim:run(1)
      local mon = sim:monitor(sim.control)
      H.eq(mon.w, case[3], case[1] .. "x" .. case[2] .. " width")
      H.eq(mon.h, case[4], case[1] .. "x" .. case[2] .. " height")
    end
  end },
  { "touching next to a turtle on a monitor still selects it", function()
    local sim = H.fleet()
    sim:run(20)
    local mon = sim:monitor(sim.control)
    local x, y = mon:findLeftOf("T10", mon:mapRight())
    sim:touch(sim.control, "top", x - 2, y + 1) -- one cell off diagonally from the glyph at x-1
    sim:run(1.5)
    H.ok(mon:contains("Pos  5, 65, 5"), mon:dumpText())
  end },
  { "GPS host panel lists hosts and can forget an offline one", function()
    local sim = H.fleet({ turtles = {} })
    sim:run(30)
    local host = sim.computers[103]
    sim:unload(host)
    sim:run(100)
    local mon = sim:monitor(sim.control)
    H.ok(mon:contains("GPS: 3/4 up (need 4)"), mon:dumpText())
    H.ok(chatText(sim):find("GPS host #103 %(Overworld%) offline"), chatText(sim))
    local x, y = mon:find("GPS: 3/4")
    sim:touch(sim.control, "top", x, y)
    sim:run(1.5)
    H.ok(mon:contains("GPS HOSTS  Overworld"), mon:dumpText())
    H.ok(mon:contains("OFFLINE"), mon:dumpText())
    H.ok(mon:contains("OK: 4 hosts, good"), mon:dumpText())
    local fx, fy = mon:find("Forget")
    sim:touch(sim.control, "top", fx, fy)
    sim:run(1.5)
    H.ok(mon:contains("forgot GPS host #103"), mon:dumpText())
    H.ok(mon:contains("GPS: 3/3 up (need 4)"), mon:dumpText())
    sim:run(11)
    H.eq(db(sim).gps[103], nil, "forgotten host removed from saved state")
  end },
  { "map remembers dimension, zoom and layers across a control reboot", function()
    local sim = H.fleet()
    sim:run(15)
    local mon = sim:monitor(sim.control)
    local x, y = mon:find("Overworld (1)")
    sim:touch(sim.control, "top", x + 16, y)       -- next dimension
    sim:run(1)
    local px, py = mon:find(" + ")
    sim:touch(sim.control, "top", px + 1, py)       -- zoom in
    sim:run(7)
    H.ok(mon:contains("Nether (1)"), mon:dumpText())
    H.ok(mon:contains("1:2"), mon:dumpText())
    sim:unload(sim.control); sim:load(sim.control)
    sim:run(3)
    H.ok(mon:contains("Nether (1)"), mon:dumpText())
    H.ok(mon:contains("1:2"), mon:dumpText())
  end },
  { "owner offline: alerts are dropped, not retried forever; later ones arrive", function()
    local sim = H.fleet({ turtles = {
      { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 },
      { id = 11, dim = "overworld", pos = { 9, 65, 5 }, heading = 1 },
    } })
    sim.players.Steve.online = false
    sim:run(50)
    sim:unload(sim.turtles[1])
    sim:run(60)
    H.eq(#sim.chat, 0)
    H.ok(sim.control.screen:contains("chat: incorrect player name/uuid"), sim.control.screen:dumpText())
    sim.players.Steve.online = true
    sim:unload(sim.turtles[2])
    sim:run(60)
    H.ok(chatText(sim):find("#11 T11 LOST"), chatText(sim))
  end },
  { "turtle without any position raises a no-position alert", function()
    local sim = H.fleet({ gps = false, turtles = { { id = 10, dim = "the_end", pos = { 1, 61, 1 } } } })
    sim:run(80)
    H.ok(chatText(sim):find("#10 T10 has no position: need 4 GPS hosts, heard 0"), chatText(sim))
  end },
  { "dimension in config that disagrees with GPS is shown", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "the_nether", cfgDim = "overworld", pos = { 3, 50, -4 } } } })
    sim:run(15)
    local t = sim.turtles[1]
    H.ok(t.screen:contains("GPS: Nether; config: Overworld"), t.screen:dumpText())
    H.eq(db(sim).turtles[10].dim, "the_nether", "GPS wins")
  end },
}
