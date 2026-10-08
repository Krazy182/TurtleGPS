local H = require("helpers")

-- An attacker computer with its own program; it never has the fleet secret.
local function attacker(sim, id, program)
  return sim:add({ id = id, dim = "overworld", pos = { 50, 70, 50 }, install = false,
    peripherals = { back = { "modem", ender = true } },
    files = { ["/startup.lua"] = program } })
end

local function db(sim)
  return sim.ser.unserialize(sim.control.fs:readFile("/fleet/data/fleet.db") or "nil")
end

return {
  { "forged heartbeats without the secret are ignored", function()
    local sim = H.fleet({ turtles = {} })
    attacker(sim, 66, [[
      rednet.open("back")
      for i = 1, 5 do
        rednet.send(1, { v = 1, f = 66, t = 1, ts = os.epoch("utc"), n = "x" .. i,
          b = '{type="hb",x=1,y=2,z=3,dim="overworld"}', m = string.rep("0", 64) }, "turtlegps")
        sleep(1)
      end
    ]])
    sim:run(15)
    H.noErrors(sim)
    local d = db(sim)
    H.eq(next(d.turtles), nil, "no fake turtle on the map")
    H.ok(sim.control.screen:contains("rejected 5"), sim.control.screen:dumpText())
    H.ok(sim.control.screen:contains("#66 bad signature"), sim.control.screen:dumpText())
  end },
  { "sniffed messages cannot be replayed", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    -- the attacker listens on the control computer's channel, then replays what it heard
    attacker(sim, 66, [[
      local m = peripheral.wrap("back")
      m.open(1)
      local captured
      while not captured do
        local _, _, ch, reply, msg = os.pullEvent("modem_message")
        if ch == 1 and type(msg) == "table" and msg.sProtocol == "turtlegps" then captured = msg end
      end
      -- a fresh rednet message id gets past CraftOS' own duplicate filter
      sleep(2)
      captured.nMessageID = captured.nMessageID + 1
      m.transmit(1, reply or 10, captured)
      sleep(60)
      captured.nMessageID = captured.nMessageID + 1
      m.transmit(1, 10, captured)
    ]])
    sim:run(80)
    H.noErrors(sim)
    local s = sim.control.screen:dumpText()
    H.ok(s:find("rejected 2"), s)
  end },
  { "pocket not on the commanders allowlist cannot act", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    sim:run(10)
    -- a real fleet member (has the secret) whose ID is not allowlisted
    sim:add({ id = 77, dim = "overworld", pos = { 9, 70, 9 },
      peripherals = { back = { "modem", ender = true } },
      files = { ["/startup.lua"] = [[
        package.path = "/fleet/?.lua;" .. package.path
        local Net = require("lib.net")
        local net = Net.new({ secret = "]] .. H.SECRET .. [[", dim = "overworld" })
        net:open()
        net:send(1, { type = "action", op = "forget", id = 10 })
        net:send(1, { type = "view_req", view = "overworld" })
        sleep(5)
      ]] } })
    sim:run(10)
    H.noErrors(sim)
    H.ok(db(sim).turtles[10], "turtle not forgotten")
    H.ok(sim.control.screen:contains("denied: #77"), sim.control.screen:dumpText())
  end },
  { "allowlisted pocket can act", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    sim:run(10)
    sim:add({ id = 50, dim = "overworld", pos = { 9, 70, 9 },
      peripherals = { back = { "modem", ender = true } },
      files = { ["/startup.lua"] = [[
        package.path = "/fleet/?.lua;" .. package.path
        local Net = require("lib.net")
        local net = Net.new({ secret = "]] .. H.SECRET .. [[", dim = "overworld" })
        net:open()
        net:send(1, { type = "view_req", view = "overworld" })
        local from, body = net:receive(5)
        local h = fs.open("/got", "w")
        h.write(body and (body.type .. " " .. #body.turtles) or "nothing")
        h.close()
      ]] } })
    sim:run(8)
    H.noErrors(sim)
    H.eq(sim.computers[50].fs:readFile("/got"), "view 1")
  end },
  { "turtle ignores signed messages that do not come from the control computer", function()
    local sim = H.fleet({ turtles = { { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 } } })
    sim:run(10)
    sim:add({ id = 77, dim = "overworld", pos = { 9, 70, 9 },
      peripherals = { back = { "modem", ender = true } },
      files = { ["/startup.lua"] = [[
        package.path = "/fleet/?.lua;" .. package.path
        local Net = require("lib.net")
        local net = Net.new({ secret = "]] .. H.SECRET .. [[", dim = "overworld" })
        net:open()
        net:send(10, { type = "upd_offer", ver = "evil0000" })
        sleep(5)
      ]] } })
    sim:run(10)
    local t = sim.turtles[1]
    local log = t.fs:readFile("/fleet/data/log.txt")
    H.ok(log:find("ignored upd_offer from #77"), log)
  end },
  { "optional turtle allowlist", function()
    local sim = H.fleet({ control = { turtles = { 10 } }, turtles = {
      { id = 10, dim = "overworld", pos = { 5, 65, 5 }, heading = 1 },
      { id = 13, dim = "overworld", pos = { 8, 65, 5 }, heading = 1 },
    } })
    sim:run(15)
    local d = db(sim)
    H.ok(d.turtles[10]); H.eq(d.turtles[13], nil)
  end },
}
