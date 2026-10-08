-- Renderer tests with a fake data source (no network), incl. the pocket-sized layout.
local H = require("helpers")
local Screen = require("mock.screen")

local function fakeView(dim)
  local now = 1760000000000
  local v = {
    type = "view", now = now, view = dim, ver = "abcd1234",
    dims = { overworld = { turtles = 2, lost = 1, gps = 4, gpsDown = 0 },
      the_nether = { turtles = 0, lost = 0, gps = 0, gpsDown = 0 },
      the_end = { turtles = 0, lost = 0, gps = 0, gpsDown = 0 } },
    turtles = {}, gps = {}, waypoints = {}, players = {}, alerts = {},
  }
  if dim == "overworld" then
    v.turtles = {
      { id = 10, label = "Miner", dim = dim, x = 4, y = 64, z = 0, h = 1, status = "idle", link = "ok", age = 1000,
        fuel = 900, fuelMax = 100000, invUsed = 3, invTotal = 15, fix = "gps", fixAge = 5 },
      { id = 11, label = "Lost1", dim = dim, x = -20, y = 64, z = 30, h = 2, status = "idle", link = "lost", age = 90000,
        fuel = 50, fuelMax = 100000, invUsed = 0, invTotal = 15, fix = "dr", lowFuel = true },
    }
    v.waypoints = { { name = "Garage", x = 0, y = 64, z = 0, kind = "garage" } }
    v.alerts = { { id = 1, kind = "lost", sev = 3, text = "#11 Lost1 LOST in Overworld: silent 1m", dim = dim, tid = 11, t = now } }
  end
  return v
end

local function harness(w, h)
  local sim = H.Sim.new()
  H.lastSim = sim
  local c = sim:add({ id = 70, kind = (w == 26) and "pocket" or "computer", boot = false })
  local screen = Screen.new(w, h, true)
  local App = H.lib(c, "ui.app")
  local actions = {}
  local source = {
    view = function(_, d) return fakeView(d) end,
    action = function(_, a) actions[#actions + 1] = a; return true, "ok " .. a.op end,
  }
  local app = App.new({ term = screen:api(), source = source, kind = "pocket", dim = "overworld" })
  app:refresh()
  app:draw()
  return app, screen, actions
end

return {
  { "pocket 26x20 compact layout", function()
    local app, s = harness(26, 20)
    H.ok(app.compact, "compact")
    local txt = s:dumpText()
    H.ok(txt:find("OVR"), txt)
    H.ok(txt:find("!1"), txt)          -- one unacked alert
    H.ok(txt:find("►"), "turtle drawn") -- miner facing east
    s:dumpRaw("test/out/pocket_map.json")
    -- tap the turtle: detail sheet appears
    local x, y = s:find("\16", 2)
    for yy = 2, 19 do
      local xx = table.concat(s.text[yy]):find("\16", 1, true)
      if xx then x, y = xx, yy break end
    end
    app:handle("mouse_click", 1, x, y)
    app:handle("mouse_up", 1, x, y)
    app:refresh(); app:draw()
    H.ok(s:contains("#10 Miner"), s:dumpText())
    H.ok(s:contains("Fuel 900 / 100000"), s:dumpText())
    s:dumpRaw("test/out/pocket_detail.json")
  end },
  { "pocket: alerts overlay acks and selects", function()
    local app, s, actions = harness(26, 20)
    local x, y = s:find("!1")
    app:handle("mouse_click", 1, x, y)
    app:draw()
    H.ok(s:contains("ALERTS 1"), s:dumpText())
    local ax, ay = s:find("#11 Lost1")
    app:handle("mouse_click", 1, ax, ay)
    H.eq(actions[1].op, "ack")
    H.eq(app.sel, 11)
  end },
  { "pocket: drag pans, keys zoom and switch dims", function()
    local app = harness(26, 20)
    local v = app:view()
    local cx = v.cx
    app:handle("mouse_click", 1, 10, 10)
    app:handle("mouse_drag", 1, 14, 10)
    app:handle("mouse_up", 1, 14, 10)
    H.ok(v.cx < cx, "dragging right moves the view west")
    H.eq(app.target, nil, "a drag is not a tap")
    local zi = v.zi
    app:handle("char", "+")
    H.eq(v.zi, zi - 1)
    app:handle("key", keys and keys.tab or 258)
    H.eq(app.dim, "the_nether")
  end },
  { "tap empty map marks a point", function()
    local app, s = harness(26, 20)
    app:handle("mouse_click", 1, 3, 4)
    app:handle("mouse_up", 1, 3, 4)
    H.ok(app.target, "target set")
    app:draw()
    H.ok(s:contains("Marked x"), s:dumpText())
  end },
  { "wide layout on a 4x3 monitor at scale 0.5", function()
    local app, s = harness(79, 38)
    H.ok(not app.compact)
    H.ok(s:contains("Overworld (2)"), s:dumpText())
    H.ok(s:contains("ALERTS 1"), s:dumpText())
    H.ok(s:contains("LOST"), s:dumpText())
    s:dumpRaw("test/out/wide_small.json")
  end },
}
