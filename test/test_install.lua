local H = require("helpers")

local function readHost(p)
  local f = assert(io.open(p, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

return {
  { "dist/install.lua is up to date with src/", function()
    local ok = os.execute("lua5.2 tools/build.lua --check > /dev/null")
    H.ok(ok == true or ok == 0, "run: lua5.2 tools/build.lua")
  end },
  { "fresh turtle: pastebin installer + setup -> shows up on the control computer", function()
    local sim = H.fleet({ turtles = {} })
    local t = sim:add({
      id = 20, kind = "turtle", dim = "the_nether", pos = { 2, 50, 2 }, heading = 3, fuel = 500,
      equip = { left = "advancedperipherals:chunk_controller", right = "computercraft:wireless_modem_advanced" },
      install = false, boot = false,
      files = { ["/install.lua"] = readHost("dist/install.lua"), ["/startup.lua"] = 'shell.run("/install.lua")' },
    })
    -- role, secret, control id, dimension, label, reboot
    sim:typeLines(t, { "", "", H.SECRET, "1", "nether", "Netherbot", "y" })
    sim:boot(t)
    sim:run(1)
    H.ok(t.fs:readFile("/fleet/config.lua"), t.screen:dumpText())
    sim:run(25)
    H.noErrors(sim)
    local cfg = sim.ser.unserialize(t.fs:readFile("/fleet/config.lua"):match("return (.*)"))
    H.eq(cfg.role, "turtle"); H.eq(cfg.dim, "the_nether"); H.eq(cfg.serverId, 1)
    H.eq(t.label, "Netherbot")
    local db = sim.ser.unserialize(sim.control.fs:readFile("/fleet/data/fleet.db"))
    local r = H.ok(db.turtles[20], "control knows the new turtle")
    H.eq(r.dim, "the_nether"); H.eq(r.x, 2); H.eq(r.h, 3); H.eq(r.label, "Netherbot")
    H.eq(r.ver, sim.ser.unserialize(sim.control.fs:readFile("/fleet/manifest")).ver, "same code version, no OTA needed")
  end },
  { "control setup generates a secret", function()
    local sim = H.Sim.new()
    local c = sim:add({ id = 1, install = false, boot = false,
      peripherals = { back = { "modem", ender = true } },
      files = { ["/install.lua"] = readHost("dist/install.lua"), ["/startup.lua"] = 'shell.run("/install.lua")' } })
    sim:typeLines(c, { "control", "", "overworld", "Steve", "42, 43", "n" })
    sim:boot(c)
    sim:run(2)
    H.noErrors(sim)
    local cfg = sim.ser.unserialize(c.fs:readFile("/fleet/config.lua"):match("return (.*)"))
    H.eq(cfg.role, "control"); H.eq(#cfg.secret, 20); H.eq(cfg.owner, "Steve")
    H.eq(cfg.commanders[1], 42); H.eq(cfg.commanders[2], 43)
    H.ok(c.screen:contains(cfg.secret), "secret shown to the player")
  end },
}
