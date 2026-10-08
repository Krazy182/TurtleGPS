local H = require("helpers")

local function ver(c)
  local m = c.env and c.fs:readFile("/fleet/manifest")
  return m and H.Sim.new().ser.unserialize(m).ver
end

local function editServer(sim, path, fn)
  local c = sim.control
  c.fs:writeFile(path, fn(c.fs:readFile(path)))
  sim:unload(c); sim:load(c) -- control recomputes its manifest at boot
end

return {
  { "code change on control propagates to every turtle and GPS host", function()
    local sim = H.fleet()
    sim:run(15)
    editServer(sim, "/fleet/app/turtle.lua", function(s) return "-- patched v2\n" .. s end)
    sim:run(90)
    H.noErrors(sim)
    local want = ver(sim.control)
    for _, t in ipairs(sim.turtles) do
      H.eq(ver(t), want, "turtle #" .. t.id .. " version")
      H.ok(t.fs:readFile("/fleet/app/turtle.lua"):find("^%-%- patched v2"), "file content")
      H.ok(t.fs:readFile("/fleet.old/app/turtle.lua"), "backup kept")
      H.ok(t.fs:readFile("/fleet/config.lua"), "config untouched")
    end
    H.eq(ver(sim.computers[110]), want, "nether gps host updated")
    H.ok(sim.turtles[1].screen:contains("Server  OK"), sim.turtles[1].screen:dumpText())
  end },
  { "crashing update rolls back and is not retried automatically", function()
    local sim = H.fleet({ gps = true, turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    sim:run(15)
    local t = sim.turtles[1]
    local good = ver(t)
    editServer(sim, "/fleet/turtle/nav.lua", function(s) return s .. "\nerror('boom')\n" end)
    sim:run(150)
    H.eq(ver(t), good, "rolled back to the working version")
    H.ok(not t.fs:readFile("/fleet/turtle/nav.lua"):find("boom"), "bad file gone")
    H.ok(t.fs:readFile("/fleet/data/crash.txt"):find("rolled back"), "crash log")
    -- and it stays on the good version instead of looping
    sim:run(60)
    H.eq(ver(t), good)
    H.ok(t.screen:contains("Server  OK"), t.screen:dumpText())
  end },
  { "update files with unsafe paths are refused", function()
    local sim = H.Sim.new()
    H.lastSim = sim
    local c = sim:add({ id = 5, boot = false, peripherals = { back = { "modem", ender = true } } })
    local Up = H.lib(c, "lib.update")
    H.ok(not Up.safePath("../startup.lua"))
    H.ok(not Up.safePath("config.lua"))
    H.ok(not Up.safePath("data/fleet.db"))
    H.ok(not Up.safePath("/abs.lua"))
    H.ok(Up.safePath("app/turtle.lua"))
  end },
}
