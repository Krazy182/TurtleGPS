-- TurtleGPS launcher, started by /startup.lua.
-- Runs this computer's role program and restarts it after a crash. If freshly updated
-- code crashes 3 times before running for a minute, the previous code is restored.
-- Hold Ctrl+T to stop and get a shell.

package.path = "/fleet/?.lua;/fleet/?/init.lua;" .. package.path

local config = require("lib.config")
local store = require("lib.store")
local Up = require("lib.update")

local APPS = { control = "app.control", turtle = "app.turtle", pocket = "app.pocket", gpshost = "app.gpshost" }

local function fail(lines)
  if term.isColor() then term.setTextColor(colors.red) end
  for _, l in ipairs(lines) do print(l) end
  term.setTextColor(colors.white)
  print("Run /fleet/bin/setup  or  edit /fleet/config.lua")
end

local cfg, err = config.load()
if not cfg then
  fail({ "TurtleGPS: cannot read /fleet/config.lua", tostring(err) })
  return
end
local problems = config.problems(cfg)
if #problems > 0 then
  fail(problems)
  return
end
if cfg.label and not os.getComputerLabel() then os.setComputerLabel(cfg.label) end

local function crashLog(msg)
  pcall(function()
    local h = fs.open("/fleet/data/crash.txt", "a")
    h.writeLine(os.epoch("utc") .. " " .. tostring(msg))
    h.close()
  end)
end

local crashes = 0
while true do
  local ok, perr
  local loaded, main = pcall(require, APPS[cfg.role])
  if not loaded then
    ok, perr = false, main
  else
    parallel.waitForAny(function()
      ok, perr = xpcall(function() main(cfg) end, debug.traceback)
    end, function()
      -- after a minute of running, new code counts as good
      sleep(60)
      local st = store.load(Up.STATE, {})
      if st.pending then
        st.pending, st.crashes = false, 0
        store.save(Up.STATE, st)
      end
      crashes = 0
      os.pullEvent("fleet_never")
    end)
  end
  if ok then return end
  if tostring(perr):find("Terminated", 1, true) then
    print("TurtleGPS stopped.")
    return
  end

  term.setCursorPos(1, 1)
  term.clear()
  if term.isColor() then term.setTextColor(colors.red) end
  print("TurtleGPS crashed:")
  print(tostring(perr))
  term.setTextColor(colors.white)
  crashLog(perr)

  local st = store.load(Up.STATE, {})
  if st.pending then
    st.crashes = (st.crashes or 0) + 1
    store.save(Up.STATE, st)
    if st.crashes >= 3 and Up.rollback() then
      print("New code keeps crashing: rolled back. Rebooting.")
      crashLog("rolled back update " .. tostring(st.ver))
      sleep(2)
      os.reboot()
    end
  end
  crashes = crashes + 1
  local delay = math.min(60, 5 * crashes)
  print("Restarting in " .. delay .. "s (hold Ctrl+T to stop)")
  sleep(delay)
  for name in pairs(package.loaded) do
    if name:match("^app%.") then package.loaded[name] = nil end
  end
end
