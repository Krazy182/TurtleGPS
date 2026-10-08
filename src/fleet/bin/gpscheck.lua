-- gpscheck: run on any computer, turtle or pocket with an ender modem.
-- Lists every GPS host that answers in this dimension, solves the position, and
-- explains what is wrong if it cannot.

package.path = "/fleet/?.lua;" .. package.path
local locate = require("lib.locate")
local P = require("lib.proto")
local U = require("lib.util")

local function color(c) if term.isColor() then term.setTextColor(c) end end

if not U.findWirelessModem() then
  color(colors.red)
  print("No wireless/ender modem attached.")
  return
end

print("Pinging GPS hosts for 3 seconds...")
local pos, err, fixes = locate.locate(3, { all = true })
fixes = pos and pos.fixes or fixes or {}

color(colors.yellow)
print(("Heard %d host(s):"):format(#fixes))
for _, f in ipairs(fixes) do
  color(f.res and f.res > 0.5 and colors.red or colors.white)
  print(("  %-20s d=%8.2f %s%s"):format(U.fmtPos(f.p), f.d, f.dim and P.dimLabel(f.dim) or "(stock host)",
    f.res and f.res > 0.5 and ("  off by " .. ("%.1f"):format(f.res)) or ""))
end

if not pos then
  color(colors.red)
  print("No fix: " .. tostring(err))
  color(colors.white)
  if #fixes < 4 then
    print("Need 4 hosts in THIS dimension, in loaded chunks, each with an ender modem running gpshost.")
  end
  return
end

color(colors.lime)
print(("Position: %d, %d, %d  (%s)"):format(pos.bx, pos.by, pos.bz, pos.dim and P.dimLabel(pos.dim) or "dimension unknown"))
color(colors.white)
print(("Raw: %.2f, %.2f, %.2f  residual %.3f"):format(pos.x, pos.y, pos.z, pos.res))
if pos.dropped then
  color(colors.orange)
  print("Ignored inconsistent host at " .. U.fmtPos(pos.dropped.p))
end
if pos.res > 0.5 then
  color(colors.orange)
  print("Residual is high: a host's configured coordinates are probably wrong.")
end
if pos.cond < 0.01 then
  color(colors.orange)
  print("Hosts are nearly coplanar: move one host up or down for accuracy.")
end
color(colors.white)
