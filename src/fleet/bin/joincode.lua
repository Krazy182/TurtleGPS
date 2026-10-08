-- joincode: prints the code other fleet computers use in setup (control ID + secret).
-- Keep it private: anyone with it can talk to your fleet.
package.path = "/fleet/?.lua;" .. package.path
local config = require("lib.config")
local J = require("lib.joincode")

local cfg = config.load()
if not cfg or not cfg.secret then
  printError("No /fleet/config.lua yet: run /fleet/bin/setup")
  return
end
local id = cfg.role == "control" and os.getComputerID() or cfg.serverId
if not id then
  printError("serverId missing from config")
  return
end
print("Join code (keep it private):")
if term.isColor() then term.setTextColor(colors.yellow) end
print(J.make(id, cfg.secret))
if term.isColor() then term.setTextColor(colors.white) end
print("On a new computer:  pastebin run <installer code> <role> <join code>")
