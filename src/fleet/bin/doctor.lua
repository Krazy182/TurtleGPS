-- doctor: checks this fleet computer and says what to fix.
-- If TurtleGPS is running, hold Ctrl+T first, then run /fleet/bin/doctor, then reboot.
package.path = "/fleet/?.lua;" .. package.path
local D = require("lib.doctor")
local store = require("lib.store")

local COLORS = { pass = colors.lime, warn = colors.orange, fail = colors.red, info = colors.lightGray }
local function color(c) if term.isColor() then term.setTextColor(c) end end

local w, h = term.getSize()
term.clear()
term.setCursorPos(1, 1)
color(colors.yellow)
print("TurtleGPS doctor")

-- progress on one line while the checks run (GPS and the control ping take a few seconds)
local _, progressY = term.getCursorPos()
local results, counts = D.run({
  out = function(r)
    term.setCursorPos(1, progressY)
    term.clearLine()
    color(colors.gray)
    term.write(("checked: %s"):format(r.title):sub(1, w))
  end,
})
local lines = {}
for _, r in ipairs(results) do lines[#lines + 1] = D.format(r) end
store.writeFile("/fleet/data/doctor.txt", table.concat(lines, "\n") .. "\n")
term.setCursorPos(1, progressY)
term.clearLine()

-- compact summary that fits a turtle screen; pages when it doesn't
local printed = progressY - 1
local function out(text, col)
  color(col)
  printed = printed + (print(text) or 1)
  if printed >= h - 1 then
    color(colors.gray)
    write("-- more: press any key --")
    os.pullEvent("key")
    local _, y = term.getCursorPos()
    term.setCursorPos(1, y)
    term.clearLine()
    printed = 0
  end
end

local ok = {}
for _, r in ipairs(results) do if r.level == "pass" then ok[#ok + 1] = r.title end end
if #ok > 0 then out("OK: " .. table.concat(ok, ", "), colors.lime) end
for _, level in ipairs({ "fail", "warn" }) do
  for _, r in ipairs(results) do
    if r.level == level then out(D.format(r), COLORS[level]) end
  end
end
if h >= 19 then
  for _, r in ipairs(results) do
    if r.level == "info" then out(D.format(r), COLORS.info) end
  end
end
out(("%d ok, %d warnings, %d problems"):format(counts.pass, counts.warn, counts.fail),
  counts.fail > 0 and colors.red or (counts.warn > 0 and colors.orange or colors.lime))
color(colors.white)
print("All details: /fleet/data/doctor.txt")
print("Send them to me: /fleet/bin/report")
return results
