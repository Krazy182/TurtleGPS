-- Dimension-aware GPS.
--
-- Our GPS hosts answer pings with { x, y, z, dim = "the_nether" }. Stock gps.locate still
-- accepts that (it only checks #msg == 3), and this locator also learns the dimension.
-- Ender modems deliver cross-dimension messages WITHOUT a distance, so only hosts in our
-- own dimension can contribute a fix.
--
-- Position is solved by least squares over all hosts heard, which also yields a residual
-- that exposes a host with mistyped coordinates.

local U = require("lib.util")
local P = require("lib.proto")

local L = {}
L.CHANNEL = 65534 -- same channel as the built-in gps API

--- fixes: list of { p = {x,y,z}, d = distance }. Returns pos {x,y,z,res,cond} or nil, reason.
function L.solve(fixes)
  local n = #fixes
  if n < 4 then return nil, "need 4 GPS hosts, heard " .. n end
  local p1, d1 = fixes[1].p, fixes[1].d
  local a11, a12, a13, a22, a23, a33 = 0, 0, 0, 0, 0, 0
  local r1, r2, r3 = 0, 0, 0
  for i = 2, n do
    local f = fixes[i]
    local qx, qy, qz = f.p.x - p1.x, f.p.y - p1.y, f.p.z - p1.z
    local c = 0.5 * (qx * qx + qy * qy + qz * qz - f.d * f.d + d1 * d1)
    a11, a12, a13 = a11 + qx * qx, a12 + qx * qy, a13 + qx * qz
    a22, a23, a33 = a22 + qy * qy, a23 + qy * qz, a33 + qz * qz
    r1, r2, r3 = r1 + qx * c, r2 + qy * c, r3 + qz * c
  end
  local det = a11 * (a22 * a33 - a23 * a23) - a12 * (a12 * a33 - a23 * a13) + a13 * (a12 * a23 - a22 * a13)
  local tr = (a11 + a22 + a33) / 3
  local cond = tr > 0 and math.abs(det) / (tr * tr * tr) or 0
  if cond < 1e-6 then return nil, "GPS hosts are coplanar (move one up or down)" end
  local x = (r1 * (a22 * a33 - a23 * a23) - a12 * (r2 * a33 - a23 * r3) + a13 * (r2 * a23 - a22 * r3)) / det
  local y = (a11 * (r2 * a33 - a23 * r3) - r1 * (a12 * a33 - a23 * a13) + a13 * (a12 * r3 - r2 * a13)) / det
  local z = (a11 * (a22 * r3 - r2 * a23) - a12 * (a12 * r3 - r2 * a13) + r1 * (a12 * a23 - a22 * a13)) / det
  local pos = { x = p1.x + x, y = p1.y + y, z = p1.z + z, cond = cond }
  local res = 0
  for i = 1, n do
    local f = fixes[i]
    local dx, dy, dz = pos.x - f.p.x, pos.y - f.p.y, pos.z - f.p.z
    local r = math.abs(math.sqrt(dx * dx + dy * dy + dz * dz) - f.d)
    f.res = r
    if r > res then res = r end
  end
  pos.res = res
  return pos
end

--- Solves, and if the result is inconsistent and there are spare hosts, drops the
--- host that disagrees (e.g. a stranger's misconfigured GPS host).
function L.robustSolve(fixes)
  local pos, err = L.solve(fixes)
  if not pos or pos.res <= 0.5 or #fixes < 5 then return pos, err end
  local best
  for skip = 1, #fixes do
    local sub = {}
    for i, f in ipairs(fixes) do if i ~= skip then sub[#sub + 1] = f end end
    local p = L.solve(sub)
    if p and (not best or p.res < best.res) then
      best = p
      best.dropped = fixes[skip]
    end
  end
  if best and best.res < pos.res then return best end
  return pos
end

--- How three-dimensional a set of host positions is: 0 = coplanar, ~1 = well spread.
function L.spread(points)
  if #points < 4 then return 0 end
  local p1 = points[1]
  local a11, a12, a13, a22, a23, a33 = 0, 0, 0, 0, 0, 0
  for i = 2, #points do
    local qx, qy, qz = points[i].x - p1.x, points[i].y - p1.y, points[i].z - p1.z
    a11, a12, a13 = a11 + qx * qx, a12 + qx * qy, a13 + qx * qz
    a22, a23, a33 = a22 + qy * qy, a23 + qy * qz, a33 + qz * qz
  end
  local det = a11 * (a22 * a33 - a23 * a23) - a12 * (a12 * a33 - a23 * a13) + a13 * (a12 * a23 - a22 * a13)
  local tr = (a11 + a22 + a33) / 3
  if tr <= 0 then return 0 end
  return math.abs(det) / (tr * tr * tr)
end

local function majorityDim(fixes)
  local count, best, bestN = {}, nil, 0
  for _, f in ipairs(fixes) do
    if f.dim then
      count[f.dim] = (count[f.dim] or 0) + 1
      if count[f.dim] > bestN then best, bestN = f.dim, count[f.dim] end
    end
  end
  return best
end

--- Pings GPS hosts. opts.all = wait the full timeout and return every host heard.
--- Returns pos { x, y, z (floats), bx, by, bz (block coords), dim, n, res, fixes } or nil, reason.
function L.locate(timeout, opts)
  opts = opts or {}
  local modem, side = U.findWirelessModem()
  if not modem then return nil, "no wireless modem" end
  local wasOpen = modem.isOpen(L.CHANNEL)
  if not wasOpen then modem.open(L.CHANNEL) end
  modem.transmit(L.CHANNEL, L.CHANNEL, "PING")

  local fixes, seen = {}, {}
  local timer = os.startTimer(timeout or 2)
  local pos
  while true do
    local ev, a, b, c, d, e = os.pullEvent()
    if ev == "modem_message" then
      if a == side and b == L.CHANNEL and c == L.CHANNEL and e and type(d) == "table"
          and tonumber(d[1]) and tonumber(d[2]) and tonumber(d[3]) then
        local key = d[1] .. "," .. d[2] .. "," .. d[3]
        if not seen[key] then
          seen[key] = true
          fixes[#fixes + 1] = {
            p = { x = tonumber(d[1]), y = tonumber(d[2]), z = tonumber(d[3]) },
            d = e, dim = P.normDim(d.dim),
          }
          if not opts.all and #fixes >= 4 then
            pos = L.solve(fixes)
            if pos and pos.res <= 0.5 then break end
            pos = nil
          end
        end
      end
    elseif ev == "timer" and a == timer then
      timer = nil
      break
    end
  end
  if timer then os.cancelTimer(timer) end
  if not wasOpen then modem.close(L.CHANNEL) end

  local use = fixes
  local ours = {}
  for _, f in ipairs(fixes) do if f.dim then ours[#ours + 1] = f end end
  if #ours >= 4 then use = ours end
  local err
  if not pos then pos, err = L.robustSolve(use) end
  if not pos then return nil, err, fixes end
  pos.bx, pos.by, pos.bz = math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor(pos.z + 0.5)
  pos.dim = majorityDim(use)
  pos.n = #use
  pos.fixes = fixes
  return pos
end

return L
