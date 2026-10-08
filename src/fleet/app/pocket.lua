-- Pocket app placeholder until milestone 2. It already checks in with the control
-- computer so it picks up the real pocket map by over-the-air update.

local P = require("lib.proto")
local Net = require("lib.net")
local Log = require("lib.log")
local Up = require("lib.update")

return function(cfg)
  local log = Log.new({ path = "/fleet/data/log.txt" })
  local net = Net.new({ secret = cfg.secret, dim = "unknown", window = cfg.replayWindow, maxBody = 200000 })
  net:open()
  local updater = Up.client({ net = net, serverId = cfg.serverId, log = log })
  local ackAt

  local function draw()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.yellow)
    print("TurtleGPS pocket #" .. os.getComputerID())
    term.setTextColor(colors.white)
    print("")
    print("The pocket map arrives in")
    print("milestone 2. This pocket")
    print("updates itself from the")
    print("control computer.")
    print("")
    print("Control #" .. cfg.serverId .. ": " .. (ackAt and "OK" or "no reply yet"))
    print("Code: " .. updater.ver)
    if updater.status then print(updater.status) end
  end

  parallel.waitForAny(function()
    while true do
      net:send(cfg.serverId, { type = P.HB, role = "pocket", ver = updater.ver })
      updater:tick()
      draw()
      sleep(10)
    end
  end, function()
    while true do
      local _, a, b, c = os.pullEvent("rednet_message")
      local from, body = net:unwrap(a, b, c)
      if from == cfg.serverId then
        if body.type == P.HB_ACK then
          ackAt = os.epoch("utc")
          updater:serverVersion(body.ver)
        else
          updater:handle(from, body)
        end
      end
    end
  end)
end
