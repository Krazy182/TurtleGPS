-- Join codes, setup fast paths, doctor and report.
local H = require("helpers")

local function readHost(p)
  local f = assert(io.open(p, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function doctorOn(sim, c)
  c.fs:writeFile("/startup.lua", 'shell.run("/fleet/bin/doctor.lua")')
  sim:unload(c); sim:load(c)
  sim:run(12)
  return c.fs:readFile("/fleet/data/doctor.txt") or ("no doctor.txt; screen:\n" .. c.screen:dumpText())
end

local function cfgOf(sim, c)
  return sim.ser.unserialize(c.fs:readFile("/fleet/config.lua"):match("return (.*)"))
end

return {
  { "join codes round-trip and catch typos", function()
    local sim = H.Sim.new()
    H.lastSim = sim
    local c = sim:add({ id = 5, boot = false })
    local J = H.lib(c, "lib.joincode")
    local code = J.make(7, "abc-def-ghij")
    H.ok(code:match("^TG%-7%-abc%-def%-ghij%-%x%x%x%x$"), code)
    local id, secret = J.parse("  " .. code .. " ")
    H.eq(id, 7); H.eq(secret, "abc-def-ghij")
    local typo = code:gsub("ghij", "ghik")
    local nid, why = J.parse(typo)
    H.eq(nid, nil); H.ok(why:find("typo"), why)
    H.eq(select(2, J.parse("hello")), "not a join code (it looks like TG-7-abcd...-1f2e)")
  end },
  { "control shows its join code; a turtle installs with it and only answers 2 questions", function()
    local sim = H.fleet({ turtles = {} })
    sim:run(3)
    local J = H.lib(sim.control, "lib.joincode")
    local code = J.make(1, H.SECRET)
    sim:char(sim.control, "j")
    sim:run(1.5)
    H.ok(sim.control.screen:contains(code), sim.control.screen:dumpText())
    local t = sim:add({
      id = 20, kind = "turtle", dim = "the_nether", pos = { 2, 50, 2 }, heading = 3, fuel = 500,
      equip = { left = "advancedperipherals:chunk_controller", right = "computercraft:wireless_modem_advanced" },
      install = false, boot = false,
      files = { ["/install.lua"] = readHost("dist/install.lua"),
        ["/startup.lua"] = 'shell.run("/install.lua", "turtle", "' .. code .. '")' },
    })
    sim:typeLines(t, { "nether", "Netherbot", "y" })
    sim:boot(t)
    sim:run(25)
    H.noErrors(sim)
    local cfg = cfgOf(sim, t)
    H.eq(cfg.role, "turtle"); H.eq(cfg.serverId, 1); H.eq(cfg.secret, H.SECRET); H.eq(cfg.dim, "the_nether")
    H.ok(t.screen:contains("Server  OK (#1)"), t.screen:dumpText())
  end },
  { "gps host set up with no questions (presets + -y)", function()
    local sim = H.Sim.new()
    H.lastSim = sim
    local c = sim:add({ id = 100, dim = "overworld", pos = { 0, 90, 0 }, peripherals = { top = { "modem", ender = true } },
      files = { ["/startup.lua"] = 'shell.run("/fleet/bin/setup.lua", "gpshost", "'
        .. H.lib(sim:add({ id = 9, boot = false }), "lib.joincode").make(1, H.SECRET)
        .. '", "dim=overworld", "x=0", "y=90", "z=0", "-y")' } })
    sim:run(3)
    H.noErrors(sim)
    local cfg = cfgOf(sim, c)
    H.eq(cfg.role, "gpshost"); H.eq(cfg.x, 0); H.eq(cfg.y, 90); H.eq(cfg.z, 0); H.eq(cfg.dim, "overworld")
    H.eq(cfg.serverId, 1)
    H.ok(c.screen:contains("GPS host #100"), "rebooted into the gps host: " .. c.screen:dumpText())
  end },
  { "a mistyped join code is rejected and asked again", function()
    local sim = H.Sim.new()
    H.lastSim = sim
    local J = H.lib(sim:add({ id = 9, boot = false }), "lib.joincode")
    local good = J.make(1, H.SECRET)
    local bad = good:sub(1, -2) .. (good:sub(-1) == "0" and "1" or "0")
    local c = sim:add({ id = 30, kind = "pocket", owner = "Steve", peripherals = { back = { "modem", ender = true } },
      files = { ["/startup.lua"] = 'shell.run("/fleet/bin/setup.lua", "pocket")' } })
    sim:typeLines(c, { bad, good, "Steve", "", "n" })
    sim:boot(c)
    sim:run(3)
    H.ok(c.screen:contains("typo"), c.screen:dumpText())
    local cfg = cfgOf(sim, c)
    H.eq(cfg.secret, H.SECRET); H.eq(cfg.owner, "Steve")
  end },
  { "doctor: healthy turtle", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    sim:run(10)
    local out = doctorOn(sim, sim.turtles[1])
    H.ok(not out:find("%[FAIL%]"), out)
    for _, want in ipairs({ "%[OK  %] Config: role turtle", "%[OK  %] Code: version", "%[OK  %] Modem",
      "%[OK  %] Control: #1 answered", "%[OK  %] GPS: 5, 65, 5 in Overworld, from 4 hosts",
      "%[OK  %] Chunky: Chunky upgrade on the left", "%[OK  %] Fuel", "%[OK  %] Slot 16" }) do
      H.ok(out:find(want), want .. "\n" .. out)
    end
  end },
  { "doctor: wrong secret, no GPS, no fuel, nothing in slot 16", function()
    local sim = H.fleet({ gps = false, turtles = {} })
    local t = H.turtle(sim, { id = 10, dim = "the_end", pos = { 1, 61, 1 }, fuel = 0, inv = {},
      config = { secret = "not-the-right-one" } })
    sim:run(5)
    local out = doctorOn(sim, t)
    H.ok(out:find("%[FAIL%] Control: no reply from #1"), out)
    H.ok(out:find("%[FAIL%] GPS: need 4 GPS hosts, heard 0"), out)
    H.ok(out:find("%[FAIL%] Fuel: 0"), out)
    H.ok(out:find("%[WARN%] Slot 16: empty"), out)
  end },
  { "doctor: control peripherals, chat test, player detector", function()
    local sim = H.fleet({ turtles = {} })
    sim:run(5)
    local out = doctorOn(sim, sim.control)
    H.ok(out:find("%[OK  %] Monitor: advanced monitor 'top': 82x33"), out)
    H.ok(out:find("%[OK  %] Chat Box: test message sent to Steve"), out)
    H.ok(out:find("%[OK  %] Speaker"), out)
    H.ok(out:find("%[OK  %] Player Detector: sees Steve at 3, 65, %-11 in Overworld"), out)
    H.ok(out:find("%[OK  %] Garages"), out)
    local found
    for _, m in ipairs(sim.chat) do if m.msg:find("doctor test") then found = true end end
    H.ok(found, "chat test message")
    sim.detectorDisabled = true
    sim.players.Steve.online = false
    out = doctorOn(sim, sim.control)
    H.ok(out:find("%[WARN%] Player Detector: getPlayerPos is disabled"), out)
    H.ok(out:find("%[WARN%] Chat Box: test message to Steve failed: player is offline"), out)
  end },
  { "doctor: gps host with a mistyped coordinate", function()
    local sim = H.Sim.new()
    local hosts = H.gps(sim, "overworld", 0, 90, 0, 100)
    sim:run(3)
    hosts[2].fs:writeFile("/fleet/config.lua", H.configText({
      role = "gpshost", secret = H.SECRET, serverId = 1, dim = "overworld", x = 80, y = 90, z = 0 }))
    local out = doctorOn(sim, hosts[2])
    H.ok(out:find("%[FAIL%] GPS: this host's x y z %(80, 90, 0%) look wrong"), out)
    -- back to serving GPS (still with the bad coordinates): its neighbours name it
    hosts[2].fs:writeFile("/startup.lua", 'shell.run("/fleet/boot.lua")\n')
    sim:unload(hosts[2]); sim:load(hosts[2])
    sim:run(2)
    out = doctorOn(sim, hosts[1])
    H.ok(out:find("%[WARN%] GPS: peer%(s%) with wrong coordinates: 80, 90, 0"), out)
    out = doctorOn(sim, hosts[3])
    H.ok(out:find("80, 90, 0 %(measured 11.3, coordinates say 80.4%)"), out)
  end },
  { "report: secret removed, doctor and logs included, uploaded unlisted", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    sim:run(10)
    local t = sim.turtles[1]
    local posted
    H.fakeHttp(sim, t, function(url, body)
      posted = { url = url, body = body }
      return "https://pastebin.com/AbCd1234"
    end)
    t.fs:writeFile("/startup.lua", 'shell.run("/fleet/bin/report.lua")')
    sim:unload(t); sim:load(t)
    sim:run(15)
    H.noErrors(sim)
    local rep = t.fs:readFile("/fleet/data/report.txt")
    H.ok(rep, t.screen:dumpText())
    H.ok(not rep:find(H.SECRET, 1, true), "secret must not be in the report")
    H.ok(rep:find("<removed, 21 chars>", 1, true), rep)
    H.ok(rep:find("[OK  ] Control: #1 answered", 1, true), rep)
    H.ok(rep:find("slot 16: minecraft:diamond_pickaxe x1", 1, true), rep)
    H.ok(rep:find("/fleet/data/log.txt", 1, true), rep)
    H.ok(posted, "uploaded")
    H.eq(posted.url, "https://pastebin.com/api/api_post.php")
    H.ok(posted.body:find("api_paste_private=1", 1, true), "unlisted")
    H.ok(posted.body:find("api_paste_expire_date=1W", 1, true), "expires")
    H.ok(not posted.body:find(H.SECRET, 1, true), "secret not uploaded")
    H.ok(t.screen:contains("https://pastebin.com/AbCd1234"), t.screen:dumpText())
  end },
  { "report without http writes the file", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    sim:run(5)
    local t = sim.turtles[1]
    t.fs:writeFile("/startup.lua", 'shell.run("/fleet/bin/report.lua")')
    sim:unload(t); sim:load(t)
    sim:run(15)
    H.noErrors(sim)
    H.ok(t.fs:readFile("/fleet/data/report.txt"))
    H.ok(t.screen:contains("Upload failed: the http API is disabled"), t.screen:dumpText())
  end },
}
