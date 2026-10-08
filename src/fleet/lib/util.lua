-- Small shared helpers.

local U = {}

function U.now() return os.epoch("utc") end

function U.clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

function U.round(v) return math.floor(v + 0.5) end

function U.copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

function U.deepcopy(v)
  if type(v) ~= "table" then return v end
  local r = {}
  for k, x in pairs(v) do r[k] = U.deepcopy(x) end
  return r
end

--- Fills missing keys in t from defaults (recursively for plain tables).
function U.merge(t, defaults)
  for k, v in pairs(defaults) do
    if t[k] == nil then
      t[k] = U.deepcopy(v)
    elseif type(t[k]) == "table" and type(v) == "table" and #v == 0 then
      U.merge(t[k], v)
    end
  end
  return t
end

function U.sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) < type(b)
  end)
  return ks
end

function U.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

--- "4s", "3m", "2h", "5d" from a duration in milliseconds.
function U.age(ms)
  if not ms then return "?" end
  local s = math.floor(ms / 1000)
  if s < 0 then s = 0 end
  if s < 60 then return s .. "s" end
  if s < 3600 then return math.floor(s / 60) .. "m" end
  if s < 86400 then return math.floor(s / 3600) .. "h" end
  return math.floor(s / 86400) .. "d"
end

function U.trunc(s, n)
  s = tostring(s)
  if #s > n then return s:sub(1, n) end
  return s
end

function U.pad(s, n)
  s = U.trunc(s, n)
  return s .. string.rep(" ", n - #s)
end

function U.padLeft(s, n)
  s = U.trunc(s, n)
  return string.rep(" ", n - #s) .. s
end

function U.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

function U.fmtPos(x, y, z)
  if type(x) == "table" then x, y, z = x.x, x.y, x.z end
  if x == nil then return "?" end
  return string.format("%d, %d, %d", math.floor(x), math.floor(y), math.floor(z))
end

function U.manhattan(a, b)
  return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

--- Finds the first wireless (ender or normal) modem. Returns wrapped modem and its side.
function U.findWirelessModem()
  local m = peripheral.find("modem", function(_, p) return p.isWireless and p.isWireless() end)
  if m then return m, peripheral.getName(m) end
  return nil
end

return U
